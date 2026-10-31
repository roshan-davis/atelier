#!/usr/bin/env python3
"""Disposable protocol model. No catalog, app launch, or production transport implementation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
import uuid


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, value):
    temp = path.with_name(path.name + '.partial')
    with temp.open('x') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def contained_file(root, name):
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise ValueError('invalid relative path')
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('symlink')
    if not current.is_file() or not current.resolve().is_relative_to(root.resolve()):
        raise ValueError('missing/nonregular/escaped file')
    return current


class Model:
    def __init__(self, root):
        self.root = root
        self.job = str(uuid.uuid4())
        self.project = str(uuid.uuid4())
        self.output = str(uuid.uuid4())
        self.sources = []
        self.abandoned = False
        self.rows = {}  # Models a persisted unique output identity, not real catalog SQL.
        self.applied = set()

    def prepare(self, sources):
        job = self.root / 'job'
        owned = self.root / 'project' / 'Sources'
        job.mkdir()
        owned.mkdir(parents=True)
        for index, source in enumerate(sources):
            staged = job / f'{index}.source'
            durable = owned / f'{index}.source'
            shutil.copyfile(source, staged)
            shutil.copyfile(staged, durable)
            self.sources.append({'id': str(uuid.uuid4()), 'path': f'Sources/{index}.source',
                                 'sha256': digest(source)})
            if digest(durable) != digest(source):
                raise ValueError('copy mismatch')
        atomic_json(job / 'request.json', {'version': 1, 'job': self.job,
                    'project': self.project, 'sources': self.sources, 'reference': self.sources[0]['id']})

    def save(self, revision, new=False, interrupt=False):
        output = str(uuid.uuid4()) if new else self.output
        generation = self.root / 'project' / f'{output}-{revision}'
        generation.mkdir()
        # Payload stands in for an independently validated TIFF. This model does not decode images.
        result = generation / 'result.tif'
        result.write_bytes(b'protocol-model-only:' + str(revision).encode())
        manifest = {'version': 1, 'job': self.job, 'project': self.project,
                    'output': output, 'revision': revision, 'sources': self.sources,
                    'reference': self.sources[0]['id'], 'result': 'result.tif', 'sha256': digest(result)}
        atomic_json(generation / 'manifest.json', manifest)
        if interrupt:
            return None
        # Pointer publication is the commit point; prior generations remain recoverable.
        atomic_json(self.root / 'project' / 'current.json', {'generation': generation.name})
        receipt = dict(manifest, result=str(result.relative_to(self.root)),
                       manifest=str((generation / 'manifest.json').relative_to(self.root)))
        atomic_json(self.root / f'receipt-{output}-{revision}.json', receipt)
        return receipt

    def register(self, receipt):
        if self.abandoned:
            raise ValueError('explicit recovery required')
        if receipt['version'] != 1 or receipt['job'] != self.job or receipt['project'] != self.project:
            raise ValueError('wrong correlation/version')
        if receipt['sources'] != self.sources or receipt['reference'] != self.sources[0]['id']:
            raise ValueError('wrong source relationships')
        result = contained_file(self.root, receipt['result'])
        manifest = json.loads(contained_file(self.root, receipt['manifest']).read_text())
        expected = dict(receipt, result='result.tif')
        del expected['manifest']
        if manifest != expected or digest(result) != receipt['sha256']:
            raise ValueError('mismatched generation/hash')
        key = (receipt['job'], receipt['output'], receipt['revision'])
        if key in self.applied:
            return 'duplicate'
        prior = self.rows.get(receipt['output'])
        if prior and receipt['revision'] <= prior['revision']:
            raise ValueError('stale revision')
        # Production: rows + applied receipt + all-source edges must commit in ONE DB transaction.
        self.rows[receipt['output']] = receipt
        self.applied.add(key)
        return 'updated' if prior else 'inserted'


class Probe(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='at021a-project-')
        self.root = Path(self.temp.name)
        originals = self.root / 'originals'
        originals.mkdir()
        self.inputs = [originals / f'{i}.raw' for i in range(3)]
        for i, path in enumerate(self.inputs):
            path.write_bytes(f'synthetic-source-{i}'.encode())
        self.hashes = [digest(p) for p in self.inputs]
        self.model = Model(self.root)
        self.model.prepare(self.inputs)

    def tearDown(self):
        self.assertEqual(self.hashes, [digest(p) for p in self.inputs])
        self.temp.cleanup()

    def test_owned_sources_survive_job_removal_and_verified_relink(self):
        shutil.rmtree(self.root / 'job')
        for entry in self.model.sources:
            self.assertEqual(digest(contained_file(self.root / 'project', entry['path'])), entry['sha256'])
        self.assertNotEqual(os.stat(self.inputs[0]).st_ino,
                            os.stat(self.root / 'project' / self.model.sources[0]['path']).st_ino)
        owned = self.root / 'project' / self.model.sources[0]['path']
        owned.unlink()
        with self.assertRaises(ValueError):
            contained_file(self.root / 'project', self.model.sources[0]['path'])
        # Relink must verify the source hash, not accept just a matching filename.
        shutil.copyfile(self.inputs[0], owned)
        self.assertEqual(digest(owned), self.model.sources[0]['sha256'])

    def test_save_refresh_and_save_as_new(self):
        self.assertEqual(self.model.register(self.model.save(1)), 'inserted')
        self.assertEqual(self.model.register(self.model.save(2)), 'updated')
        self.assertEqual(self.model.register(self.model.save(1, new=True)), 'inserted')
        self.assertEqual(len(self.model.rows), 2)
        self.assertTrue(all(len(row['sources']) == 3 for row in self.model.rows.values()))

    def test_replay_relaunch_and_interrupted_save(self):
        first = self.model.save(1)
        self.model.register(first)
        self.assertIsNone(self.model.save(2, interrupt=True))
        current = json.loads((self.root / 'project/current.json').read_text())
        self.assertTrue(current['generation'].endswith('-1'))
        # Simulate persistence/reload of the transaction state.
        saved = json.loads(json.dumps(list(self.model.rows.values())))
        self.model.rows = {r['output']: r for r in saved}
        self.assertEqual(self.model.register(first), 'duplicate')
        second = self.model.save(3)
        self.assertEqual(self.model.register(second), 'updated')
        self.assertEqual(self.model.register(first), 'duplicate')

    def test_reject_invalid_receipts_and_abandoned_job(self):
        receipt = self.model.save(1)
        variants = [dict(receipt, version=2), dict(receipt, job='foreign'),
                    dict(receipt, sources=[]), dict(receipt, result='../escape.tif'),
                    dict(receipt, result='/etc/passwd'), dict(receipt, sha256='bad')]
        link = self.root / 'alias.tif'
        link.symlink_to(self.root / receipt['result'])
        variants.append(dict(receipt, result='alias.tif'))
        for bad in variants:
            with self.assertRaises(ValueError):
                self.model.register(bad)
        self.model.abandoned = True
        with self.assertRaises(ValueError):
            self.model.register(receipt)
        self.assertFalse(self.model.rows)

    def test_no_receipt_for_partial_output_and_no_stale_overwrite(self):
        self.model.save(1, interrupt=True)
        self.assertEqual(list(self.root.glob('receipt-*.json')), [])
        newer = self.model.save(3)
        self.model.register(newer)
        older = self.model.save(2)
        with self.assertRaises(ValueError):
            self.model.register(older)
        self.assertEqual(self.model.rows[self.model.output]['revision'], 3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
