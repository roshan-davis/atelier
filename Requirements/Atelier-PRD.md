# Photo Catalog & Editor PRD

Oct 25, 2026 · Rosh · Revised Oct 26, 2026 (UX principles and import flow; import entries; Phase 1 before Phase 0; before/after compare views; export dialog; panels, zoom and right-click menus; Tone Curve, HSL / Color and Color Grading panels; editable point curve, panel below the toolbar, slider rows; Settings window, custom keys, resizable panel; themes)

Live doc with diagrams: https://claude.ai/artifact/1T8xvdGuJTcGPTHStzDJvn

## Overview

Atelier (working name) is a native macOS photo catalog and non-destructive RAW editor for personal use, with first-class hooks for external editors and local AI models. It replaces a Lightroom subscription for one photographer and artist, and treats AI models as pluggable processing steps rather than a fixed feature set.

**Problem.** Lightroom locks the catalog, the develop pipeline and AI features into one subscription and one cloud. Local AI image models (Qwen-Image-Edit, FLUX.2 Klein, upscalers, segmenters) now match or beat built-in AI tools, but there is no catalog that can route a photo through them and keep the result versioned next to the original.

**Goals**

1. Catalog 100k+ images across local drives and the megham NAS, either in place or copied into a managed library.
2. Non-destructive develop module at Lightroom Classic parity for everyday work: RAW decode, tone, color, HSL, curves, local masks, presets.
3. Round-trip any photo to any external editor (Photoshop, Affinity, Pixelmator Pro, GIMP, Krita) and re-import the result as a stacked version.
4. Run AI edits through pluggable local backends (ComfyUI, Core ML, MLX) with a model registry that tracks license and allowed use.
5. Export web-ready images for roshandavis.com and social posts with presets for size, color space, watermark and metadata.

**Non-goals**

- Cloud sync, multi-user catalogs or mobile apps in v1.
- Training or fine-tuning models inside the app.
- Video editing (video files are cataloged and previewed only).
- Windows or Linux support.

## Target user and use cases

One user: a photographer and watercolor artist running an art business, editing on an Apple Silicon Mac, with originals split between local drives and a NAS. Every use case below must work fully offline except NAS access.

| # | Use case | Flow | Priority |
| --- | --- | --- | --- |
| U1 | Import a shoot | Card or folder, copy to managed library or reference in place, auto-tag, build previews; the photos land in a named import entry, new or existing | P0 |
| U2 | Cull and rate | Grid and loupe, flags, stars, color labels, compare and survey views, keyboard-only | P0 |
| U3 | Develop a RAW | Basic, tone curve, HSL, detail, lens corrections, local masks, sync settings across a batch | P0 |
| U4 | Photograph artwork | Color-checker profile, perspective correction, crop to canvas edge, accurate white balance | P0 |
| U5 | Round-trip to Photoshop or Affinity | Edit In, render a 16-bit TIFF or PSD, re-import as a stacked version | P0 |
| U6 | AI edit | Remove an object, replace a background, relight, upscale, using a chosen local model, result saved as a version | P0 |
| U7 | Batch AI | Run an AI recipe (for example, denoise then upscale) over a collection in a queue | P1 |
| U8 | Find anything | Search by keyword, EXIF, location, color, or natural language ("red barn in fog") | P1 |
| U9 | Publish to the website | Export preset: long edge 2048 px, sRGB, watermark, stripped GPS, WebP and JPEG | P0 |
| U10 | Work while the NAS is off | Browse, rate and edit smart previews; changes apply when the NAS reconnects | P1 |

## User experience principles

Every feature follows these rules. A feature is not done until it meets them.

1. **Start with the task, not a system dialog.** A command opens Atelier's own dialog first; file pickers are a step inside it, never the entry point.
2. **Show what will happen before it happens.** Dialogs preview the outcome (for example "Import 128 photos" on the button) and disable the action until it can succeed.
3. **Drag and drop everywhere it makes sense.** Folders and photos dropped on the window or a dialog do the obvious thing.
4. **Long work runs in the background, visibly.** Imports, previews, exports and AI jobs show progress, can be cancelled, and never block browsing or editing.
5. **Results appear as they arrive.** A new import is selected in the sidebar as soon as it starts, and photos fill in while it runs.
6. **Nothing destructive without a clear confirmation.** Deleting a list explains what is kept ("the photos stay in your catalog and on disk"). Originals are never modified.
7. **Errors name the file and the reason**, and the rest of the batch continues. Problems are listed on request instead of interrupting with alerts.
8. **Keyboard first for repeated work.** Culling, rating, flagging, labels and view switching all have single-key shortcuts; every command is in a menu.
9. **Sensible defaults, remembered choices.** Names default to the folder or event, and the last import mode and library folder are remembered.
10. **Plain language.** Labels describe what happens to the user's photos ("Leave files where they are", "Copy into my library folder"), not internal terms.

### Import flow

1. File > Import Photos (Shift-Cmd-I), the toolbar button, or dropping folders or photos on the window opens the Import dialog.
2. The dialog has four parts, top to bottom:
   - **Photos:** a drop zone with "Choose Folders or Photos…". Each chosen source shows its photo count and can be removed. "Add More…" adds sources.
   - **Import into:** a new import entry (named after the first folder by default) or an existing one.
   - **Files:** leave files where they are, or copy them into the library folder (dated folders, hash-verified).
   - **Keywords:** optional, applied to every photo.
   - **Culling:** optional "Cull before importing" (see Culling).
3. The Import button reads "Import N Photos" and is disabled until at least one photo is found.
4. After Import, the dialog closes, the import entry is selected, photos appear as they are cataloged, and the status bar shows progress with Cancel.
5. When done, the status bar summarizes imported, already-in-catalog and unreadable files, with "Show Problems" listing any failures.

### Culling (decided Oct 26, 2026)

Culling picks the keepers from groups of similar shots (bursts, the same scene taken a few times). It runs before an import or on any import entry later, in the same Cull view.

- **Before importing:** the Import dialog has "Cull before importing". With it on, the button reads "Continue to Culling…" and the Cull view opens on the chosen photos. Only kept photos go into the import entry, with the options chosen in the dialog. The shots not kept are still cataloged (flagged Rejected, outside the entry, under All Photographs and their folder) so they can be re-reviewed; in copy mode they are copied too.
- **On an import entry:** right-click the entry in the sidebar > Cull…, or Library > Cull Import…. When done, kept photos are flagged Picked and the others Rejected (nothing is removed; the Rejected filter hides them and culling again changes it).
- **Grouping:** photos are ordered by capture time; a photo joins the group before it when it was taken close in time (within a minute) and matches it, and also matches the group's first shot a little more loosely, so a slow pan doesn't chain a whole shoot. A Grouping slider goes from Tight to Loose and regroups instantly. Single shots are listed last and kept.
- **Match (updated Oct 27, 2026):** Rosh asked for more than one way of telling similar shots apart. A Match control at the top picks one, and is remembered:
  - **Same Frame:** only shots framed alike from the same spot, where people moved slightly, blinked or changed expression. Measured pixel by pixel: the share of the frame that changed, ignoring exposure differences and a tiny camera shake.
  - **Similar Shots** (default): also the same scene reframed: slightly zoomed or recomposed, people in the background or far away moving, focus on a different subject. Measured by lining the shots up (zooms up to about a quarter, small shifts) and by Vision feature prints. Shots under a second apart (a burst) always join.
  - Each group is labelled Same frame or Similar shots, so a Similar Shots cull still shows which groups are near-identical.
- **RAW+JPEG:** a RAW and the JPEG (or HEIC, TIFF) shot with it are one frame in culling, whatever the RAW+JPEG setting: the RAW is analyzed and shown, marked RAW+JPG, and keeping or dropping it applies to both.
- **Suggested keeper:** in each group Atelier suggests the best photo: the sharpest, and where there are faces, the best face capture quality (eyes open, in focus). It is marked Suggested and starts as the keeper; any photo can be kept or dropped, and a group can keep several.
- **Layout:** groups as rows of thumbnails on the left (kept photos with a check, the rest dimmed), the focused photo large on the right with its sharpness and face quality, counts and the Grouping slider on top, Cancel and Import N Photos (or Done) at the bottom.
- **Keys:** arrows move between photos and groups, P keeps, X drops, Space toggles, Return finishes, Esc cancels.
- **Groups are remembered.** Every photo culled with others shows "◫ n" (the group's size) in the grid. Photo > Show Cull Group (⇧⌘G), or right-click > Show Cull Group (n Shots), opens the Cull view on that one group: the keeper next to every shot it beat, rejected ones included, with the same large preview to re-review and change the keeper. A shot kept on re-review is flagged Picked and joins the group's import entry.
- Analysis runs in the background with progress; for photos already cataloged it reads the files where they are.

### RAW+JPEG pairs (decided Oct 27, 2026)

Cameras set to RAW+JPEG write DSC_0001.NEF and DSC_0001.JPG for one picture. Rosh wants these grouped, with only the RAW shown, and kept separate from culling (which groups different frames).

- **What pairs:** files in the same folder with the same name apart from the extension, where exactly one is a RAW (NEF, CR2, CR3, ARW, RAF, ORF, RW2, DNG and the other RAW formats). The others (JPEG, HEIC, TIFF, PNG) are its siblings.
- **Setting:** Settings > Import > "Show RAW+JPEG pairs as one photo", on by default. On: the grid, filmstrip and counts show only the RAW, with a "RAW+JPG" badge; the inspector lists the sibling files under "Shot with". Off: every file is its own photo. Changing it takes effect at once; nothing is re-imported.
- **Cataloging:** every file is still imported and cataloged (with its own hash and metadata), so turning the setting off loses nothing.
- **Edits follow the RAW:** while grouped, ratings, flags, color labels, keywords, collections and import entries set on the RAW are set on its siblings too. Develop settings, Edit In, AI and export use the RAW only, as in Lightroom.
- **Not hidden:** Edit In and AI results and virtual copies, even when their name matches a RAW.

### Virtual copies (decided Oct 26, 2026)

Rosh wants several treatments of one photo (colour and black and white, two crops) without duplicating the file, as in Lightroom.

- **Create:** right-click a photo (grid, loupe or Develop) > Create Virtual Copy, or Photo > Create Virtual Copy (⌘'). With several photos selected, each gets a copy. The new copies are selected.
- **What a copy starts with:** the photo's current develop settings (history starts at one step, "Virtual Copy"), rating, color label, title, caption, keywords, collections and import entries. Flags are not copied.
- **Independent:** each copy has its own develop settings, history, snapshots, rating, flag, label and keywords. Editing a copy never changes the original or other copies.
- **Shown in the stack:** copies sit right after the original in the grid with a "⧉ Copy n" badge; the original shows the stack count. A copy of a copy stacks on the same original. The loupe title and the inspector name the copy.
- **Remove:** right-click > Remove Virtual Copy…, or Photo > Remove Virtual Copy…, after a confirmation. Only catalog data goes; the original and its file are never touched.
- **Files:** a copy shares the original's file. Export names it `name-Copy1.jpg`. XMP sidecars are written for the original only. Re-importing the folder never mistakes a copy for the file. Culling an import entry skips copies.

### Filmstrip (decided Oct 27, 2026)

Rosh asked for Lightroom's Filmstrip: a bottom drawer with the thumbnails of the current list.

- **What it shows:** the photos of the current source (All Photographs, a volume, folder, collection or import entry) with the filter bar applied, in the same order as the grid. A thin header names the source and shows the photo count, how many are selected, "n of N" for the current photo and its filename (plus "Copy n" for a virtual copy).
- **Where:** across the full width of the window, under the left panel, the photo area and the right panel, as in Lightroom Classic. It is shown in Grid, Loupe and Develop.
- **Selection:** the photo being worked on has a bright border, and other selected photos have a softer one. Click selects, ⌘-click adds or removes, ⇧-click selects a run, and double-click opens the photo in Loupe from the grid. The strip scrolls to keep the current photo in view, including when arrow keys move through photos. Rejected photos are dimmed, and flag, stars, stack and cull badges match the grid.
- **Collapse and open:** a small arrow tab centered on the bottom edge (▾ to hide, ▴ to show), View > Show Filmstrip, or F6.
- **Size:** drag the Filmstrip's top edge to make thumbnails bigger or smaller (56 to 220 pt).
- **Remembered:** open or collapsed, and the height, are kept between launches.

### Masking (decided Oct 27, 2026)

Rosh asked for Lightroom's graduated, radial and brush adjustments, edited through masks, the way Lightroom Classic does it.

- **Open:** the Masking button (dashed circle) in the tool strip under the histogram, Shift+W, or one of the tool keys: M for Linear Gradient, Shift+M for Radial Gradient, K for Brush. Opening Masking closes Crop and AI. The photo zooms as in Develop (the zoom bar, Z, pinch or ⌘-scroll); scroll, hold Space and drag, or drag on empty photo to move around while zoomed. Pins, handles and the brush scale with the zoom. Esc or Done (Return) closes it; the masks keep working after it closes.
- **Masks panel:** at the top of the Masking section, a list of the photo's masks ("Mask 1", "Mask 2", in creation order, renameable by double-click). Each mask lists its parts (components) with a small icon and add, subtract or intersect badge. Create New Mask offers Brush, Linear Gradient, Radial Gradient, Luminance Range, Select Subject and Select Object. With a mask selected, Add and Subtract offer the same list; Intersect is in the mask's right-click menu (as in Lightroom: Intersect Mask With). Each mask has an eye to hide its effect, and a right-click menu with Rename, Duplicate, Invert, Intersect Mask With, and Delete. A part's right-click menu has Invert, Switch to Add / Subtract, and Delete. Delete removes the selected part (the whole mask when it was the last part).
- **Show Overlay:** a checkbox (and O) tints the selected mask red on the photo, so it is clear where the adjustment lands.
- **Linear Gradient:** drag on the photo from where the adjustment is full to where it fades out. Three lines show the start, middle and end; drag the pin in the middle to move it, drag the end handles to widen, narrow or turn it.
- **Radial Gradient:** drag from the center outward to draw an ellipse. Drag the pin to move it, the four edge handles to resize it, and the round handle above it to rotate it. Feather (0 to 100, default 50) softens the edge; the inner dashed ellipse shows where the full effect ends. By default the adjustment is inside; Invert puts it outside.
- **Brush:** paint on the photo. Size, Feather and Flow sliders, and Paint / Erase (or hold ⌥ to erase while painting). [ and ] change the size, Shift+[ and Shift+] the feather. The cursor shows the size, with an inner circle for the feather. The stroke always reaches where the mouse was released.
- **Luminance Range:** keeps the parts of the mask whose brightness falls in a range (two sliders, 0 to 100) with Smoothness for the falloff. Usually added with Intersect to limit a gradient to the sky or the shadows.
- **Select Subject:** finds the main subject (people, animals, objects in front) with Apple's Vision framework on the Mac. Invert it to adjust the background.
- **Select Object:** drag a box around something; Vision looks only inside the box, so smaller subjects are found too. Drag the pin to move the box. Select Subject and Select Object have a Feather slider (default 20) to soften Vision's hard edge, and the panel says so when Vision finds nothing.
- **Soft edges:** feathered masks keep their in-between values all the way to the render, so a 50% feather looks like one.
- **Combining parts:** Add unions a part into the mask, Subtract cuts it out, and Intersect keeps only where both overlap.
- **Adjustments per mask:** under the list, the selected mask's sliders, as in Lightroom: Amount (0 to 200%, scales all of the mask's sliders), Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Saturation, Sharpness and Noise, plus Invert. Double-click a slider's name to reset it; Reset Sliders clears them all.
- **Where it sits in the pipeline:** masks are applied after the global adjustments and before vignetting and grain (pipeline step 6). Masks are tied to the photo, not to the frame: they stay on the same spot when the crop, straighten, rotation or flips change.
- **History and storage:** every change is a history step (New Mask: Linear Gradient, Mask 1 Exposure +0.50, Edit Mask 1). Masks are saved in the develop settings JSON with the photo, copied by Copy and Paste Settings and by virtual copies, and optional in presets (the Masks part, off by default, as Lightroom's Masking checkbox). They render in previews, exports, Edit In and AI.
- **Later:** Select Sky and Background, color range, and Lightroom's Auto Mask for the brush.

### Camera-matched RAW look (decided Oct 27, 2026)

Rosh saw a selected photo appear with one look, then turn darker a moment later. The first image was the JPEG preview the camera embeds in the RAW (Nikon Zf and Z6: Picture Control and Active D-Lighting); the second was Apple's RAW engine at default settings, which has none of that processing.

- **Default look:** every RAW starts from the camera's look, like Lightroom's Camera Matching profiles. Atelier compares the embedded preview with its neutral render and fits a tone curve (histogram matching on brightness, smoothed, never moving a tone by more than 30%) and a saturation factor (0.85 to 1.35). It is applied right after decode (pipeline step 1), before any of the user's adjustments, so sliders at zero show the camera's look.
- **Everywhere:** Develop, Before/After, the histogram, masks, the loupe preview, thumbnails of edited photos and exports all use it, so the grid's embedded thumbnail, the loupe and Develop agree and nothing visibly swaps.
- **No usable preview:** files without an embedded preview (or with one of a different shape) keep Apple's render. JPEG, HEIC and other non-RAW files are unchanged.
- **Previews:** previews from before this change are rebuilt once on first launch.
- **Profile choice:** built Oct 27, 2026 as the Profile menu in Basic (see Profile, Lens Corrections and Transform).

### Profile, Lens Corrections and Transform (decided Oct 27, 2026)

Rosh asked whether a camera profile is worth having, and for Lightroom's perspective tools: corrections from the lens profile, Upright, and guides drawn on the photo.

- **Profile (top of Basic):** a Profile menu like Lightroom's. Camera Matching (the default; the camera-matched look above, fitted per photo so it follows the Picture Control and Active D-Lighting each shot was taken with) and Apple Neutral (Apple's RAW render with no camera look: flatter, with more highlight room, a starting point for heavy edits). Non-RAW files show the menu dimmed. The profile is applied at decode, under all the sliders, and is a history step ("Profile: Apple Neutral"). Fixed per-camera profiles (one look for every Zf or Z6 file, or a ColorChecker profile for artwork) come later; the per-photo match already follows each shot's camera settings, so they are not needed now.
- **Lens Corrections panel** (after Detail, as in Lightroom Classic):
  - **Profile:** Enable Profile Corrections (on by default for RAW files) applies the distortion and vignetting corrections Apple's RAW engine has for the camera and lens, which for Nikon Z files come from the correction data the camera writes into the NEF. The panel shows the lens name from the file. When the RAW engine has no corrections for the file (or it is not a RAW), the checkbox is dimmed with "No lens corrections for this photo".
  - **Manual:** Distortion (-100 to 100; positive removes barrel distortion, negative removes pincushion) and Lens Vignetting Amount (-100 to 100; positive brightens the corners) with Midpoint. These act on the whole uncropped photo around its center, unlike Effects > Post-Crop Vignetting.
  - **Later:** Remove Chromatic Aberration, Defringe, and choosing a lens profile by hand.
- **Transform panel** (after Lens Corrections):
  - **Upright:** buttons Off, Auto, Level, Vertical, Full and Guided. Atelier finds straight lines in the photo (after lens corrections) and solves for the tilt that makes them straight: Level makes horizontal lines level (rotation only); Vertical also makes vertical lines parallel (vertical perspective and rotation); Full also corrects horizontal perspective; Auto does the same as Full but holds back when the lines are weak, so it never warps a photo hard on thin evidence. If too few lines are found, the button reports "Not enough straight lines found" and nothing changes. Upright's correction is stored with the photo, so it never changes on its own; clicking the mode again recomputes it.
  - **Guided:** the Guided button (or Shift+T) shows the photo with the guides tool, like Lightroom: drag along an edge that should be vertical or horizontal to draw a guide (up to four). Each guide is treated as vertical or horizontal by which it is closer to, and the correction updates as each guide is drawn. Drag a guide's ends to move them; select a guide and press Delete to remove it. Two vertical guides fix converging verticals (the main use for buildings and artwork); add horizontal guides to also fix the horizontal perspective. Esc or Done closes the tool.
  - **Manual sliders**, added on top of Upright: Vertical (-100 to 100; negative widens the top, for buildings shot from below), Horizontal (-100 to 100), Rotate (-10° to 10°), Aspect (-100 to 100; positive stretches width), Scale (50 to 150%), X Offset and Y Offset (-100 to 100).
  - **Constrain Crop:** off by default. When on, the corrected photo is enlarged just enough that no empty edges show. With it off, the areas the correction leaves empty show as light gray, as in Lightroom.
- **Pipeline:** profile corrections at decode, then manual lens vignetting and distortion, then the Transform, all in step 1, before every adjustment, the masks and the crop. Masks, the crop and Select Subject work on the corrected photo, so changing the Transform after drawing a mask keeps the mask on the same spot of the frame.
- **Storage and sharing:** all of it is part of the develop settings (history steps, Copy/Paste Settings, virtual copies). Presets get Profile, Lens Corrections and Transform parts, off by default, as in Lightroom's preset dialog. Before/After keeps the lens corrections and Transform, like the crop, so the two line up.

### Match Look to a Reference (decided Oct 27, 2026)

Rosh asked for color matching from a reference picture: give a photo the look of another image (a downloaded photo, a film still, or one of their own edited shots). Design discussion: https://claude.ai/artifact/1wZzQU68nnQv4qpzVR5Rj6

- **Result is ordinary sliders:** the match works out Develop settings (White Balance, Exposure, the RGB Tone Curve, Saturation and Color Grading, later HSL) that make the photo's render look like the reference. Applying it is one history step ("Match Look: <reference name>") that can be edited, undone, copied, synced or saved as a preset like any other edit. No generative AI touches the pixels, so the licensing rule does not apply. No exact-match 3D LUT mode: everything stays editable with sliders.
- **Dialog first:** Develop > Photo > Match Look to Reference… (⇧⌘M) opens the Match Look dialog; so does Match Look to Reference… in the right-click menu on photos (grid, loupe, filmstrip and Develop), which opens the clicked photos in Develop first (added Oct 27, 2026 at Rosh's request). The reference is picked only inside the dialog, not from the filmstrip or a right-click menu:
  - **Choose File…** (the main path): any image on the Mac (JPEG, PNG, HEIC, TIFF, or a RAW's embedded preview). Dragging an image from Finder onto the reference slot does the same.
  - **Recent References:** the last 8 reference files. Only each file's location and a small thumbnail are remembered; the file is not copied into the catalog. A moved or deleted file shows as missing.
  - **Use a Photo from the Catalog…:** a secondary choice, for matching a set to a shot already edited; the catalog photo is used with its current edits.
- **Match and preview inside the dialog:** the reference on the left and a live preview of the open photo on the right; press and hold the preview to see Before. Checkboxes for White Balance, Tone and Color (all on by default). Strength (0 to 100, default 100) blends between the photo's current settings and the matched ones, and the preview follows it. Nothing changes on the photo until Apply; Cancel leaves it exactly as it was. Strength is baked in on Apply; to change it later, edit the sliders or run the match again.
- **Match Areas (optional):** a toggle that shows a box on the reference and a box on the photo. Drag each box over the parts that should match (skin to skin, sky to sky). The fit weighs the boxed areas most (three quarters of the weight) and the rest of each image a little, so the whole photo still moves sensibly. This handles references whose content differs from the photo.
- **More than one photo:** when several photos are selected in the filmstrip, the dialog offers Same settings (fit once on the open photo and apply those values to all) or Match each photo (fit each photo to the reference on its own, for mixed light; runs in the background with progress and Cancel in the status bar). Each photo gets its own history step.
- **How the fit works (Phase 1):** both images are measured at about 384 pixels in Oklab, a perceptual color space, after the photo's current profile, lens corrections and crop. In order: White Balance moves Temp and Tint until the photo's average midtone color matches the reference's; Exposure moves the median brightness (at most ±2 EV); the RGB Tone Curve is fitted by histogram matching on brightness (smoothed, rising, never moving a tone by more than 30%, five points so it stays editable); Saturation matches the reference's typical chroma (-60 to +60); Color Grading Shadows and Highlights take any remaining color difference between dark and bright tones (split toning). Each step renders the photo through the real Develop pipeline and corrects itself against that render, so the result reflects what the sliders actually do. Every value is clamped, so an odd reference can't wreck the photo.
- **Later phases:** HSL band fit and a final refinement pass over all fitted sliders (Phase 2); Protect Skin Tones and automatic subject/background areas from the Select Subject mask (Phase 3). AI color-transfer models stay experiments only.

## Scope by release

The MVP proves the catalog, a usable develop module and one AI backend. Full develop parity and the plugin system come in v1.

| Area | MVP | v1 | Later |
| --- | --- | --- | --- |
| Catalog | Referenced and copied import, import entries, ratings, flags, labels, keywords, folders, collections | Smart collections, stacks, offline NAS mode, duplicate detection | Face grouping, map view |
| Develop | RAW decode, white balance, exposure, contrast, highlights, shadows, crop, straighten, history, snapshots | Tone curve, HSL, color grading, lens profiles, linear and radial masks, AI subject and sky masks, presets, batch sync | Brush masks with edge-aware refine, HDR and panorama merge, focus stacking |
| External editors | Edit In with any app, TIFF round-trip, stacked version | PSD round-trip, per-app settings, file watcher for live updates | Smart-object style re-edit |
| AI | ComfyUI backend, 3 recipes (object removal, upscale, background replace) | Core ML and MLX backends, recipe builder, batch queue, model registry with license gate | Natural-language search, auto-keywording, MCP server for agents |
| Export | JPEG, HEIC, 16-bit TIFF, PNG; long edge, sharpen for screen, sRGB, Display P3 or Adobe RGB; metadata all, without location, or none; quick settings for website and full size. WebP waits for an encoder (macOS ImageIO reads WebP but cannot write it) | Watermark, metadata rules, named presets, publish to folder | WooCommerce and Instagram publish services |

## Catalog and library management

The catalog never modifies an original file. Every photo is a database record pointing at a file by volume ID and relative path, so moving or remounting a drive does not break links.

### Import modes

1. **Reference in place.** Files stay where they are (local or NAS). The app records the volume UUID, relative path, file size, modified time and a content hash.
2. **Copy to managed library.** Files are copied into a dated folder template (default `YYYY/YYYY-MM-DD Event/`), renamed by an optional pattern, verified by hash after copy, and optionally backed up to a second destination in the same pass.
3. **Watch folder.** A folder is monitored with FSEvents; new files import automatically with a chosen preset (used for tethering and for the ComfyUI output folder).

### Requirements

- Formats: all RAW formats Apple's RAW engine supports, plus DNG, JPEG, HEIC, TIFF, PNG, WebP, PSD (composite only). Video files cataloged with poster frames.
- Import applies a metadata preset (copyright, creator, keywords) and a develop preset.
- Previews: a 256 px thumbnail and a 2560 px preview per photo, generated in the background. Thumbnails come first, from the file's embedded preview when it is large enough, and appear in the grid while the import is still running; 2560 px previews follow at lower priority, except the photo open in the loupe, which jumps the queue. Optional smart preview (lossy DNG, 2560 px long edge) for offline editing.
- Metadata: EXIF, IPTC and XMP read on import. Ratings, labels, keywords and develop settings written to XMP sidecars on demand or automatically, so other apps can read them.
- Organization: folders mirror disk; collections and collection sets are virtual; smart collections are saved queries; stacks group versions and bursts.
- Import entries: every import lands in a named entry listed in the sidebar (default name: the source folder, or the event name for copied imports). An import can create a new entry or add to an existing one; files already in the catalog join the entry without being imported twice. Entries can be renamed and deleted, and photos added to or removed from them by hand. Removing a photo from an entry, or deleting an entry, never removes the photo from the catalog.
- One catalog: a single catalog holds the whole library. Separate sets of photos are kept apart with import entries, folders and collections, not separate catalogs.
- Search: filter bar on any metadata field, combined with AND/OR. Full-text over keywords, titles and captions.
- Duplicate detection by content hash (exact) and perceptual hash (near-duplicates).

### NAS and offline volumes

- Each volume shows online or offline in the sidebar. Offline photos stay browsable through previews.
- Ratings, keywords and develop edits on offline photos are stored in the catalog and synced to XMP when the volume returns.
- Edits that need the original (export, Edit In, AI on full resolution) queue until the volume is online, or run on the smart preview if the user chooses.
- Missing-file finder: relink by hash when files move outside the app.

## Develop module

Edits are a versioned list of parameters stored in the catalog, rendered live on the GPU from the original. Nothing is baked into a file until export, Edit In or an AI step.

### Pipeline order

1. RAW decode and demosaic (CIRAWFilter): white balance, exposure baseline, noise reduction, profile lens corrections, then the profile (camera-matched base look or Apple Neutral), manual lens corrections and the Transform (Upright and the perspective sliders).
2. Linear-light global adjustments: exposure, highlights, shadows, whites, blacks.
3. Tone: contrast, tone curve (parametric and point, per channel).
4. Color: vibrance, saturation, HSL (8 hues), color grading (shadows, midtones, highlights).
5. Detail: sharpening with masking, texture, clarity, dehaze.
6. Local adjustments: each mask carries its own subset of steps 2 to 5.
7. Geometry: crop, straighten, post-crop vignette.
8. Output transform: working space (linear Rec. 2020 or ProPhoto) to display or export space.

### Tools and requirements

- Live preview at 60 fps on a 2560 px proxy; full-resolution render once the photo is zoomed past fit, and for export.
- The right column sits beside the photo and below the toolbar (never under it), like Lightroom's panel strip. Drag its left edge to resize it (280 to 560 points); its content always fits the column.
- Panels follow Lightroom's layout and order in the right column, each collapsible, remembered between sessions, with a dot and a reset button when it has edits. Right-click a panel header for Solo Mode (one panel open at a time), Expand All and Collapse All.
  - Histogram: RGB, from the current render, with shadow and highlight clipping warnings.
  - Basic: Profile (Camera Matching, Apple Neutral), White Balance (Temp, Tint), Tone (Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Presence (Texture, Clarity, Dehaze, Vibrance, Saturation).
  - Tone Curve: an editable point curve for RGB, Red, Green and Blue, drawn over that channel's histogram: click the curve to add a point and drag it, double-click a point to remove it, reset per channel. The overall result of Basic tone and the region sliders (Highlights, Lights, Darks, Shadows) shows as a faint line under the RGB curve.
  - HSL / Color: eight bands (Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta) with Hue, Saturation and Luminance, shown one channel at a time or All, on colored slider tracks. Grays are never affected.
  - Color Grading: Shadows, Midtones, Highlights and Global wheels (drag for hue and saturation, slider for luminance), plus Blending and Balance.
  - Detail: Sharpening (Amount, Radius), Noise Reduction (Luminance, Color).
  - Effects: Post-Crop Vignetting (Amount, Midpoint), Grain (Amount, Size).
  - Lens Corrections and Transform (between Detail and Effects; see Profile, Lens Corrections and Transform under User experience principles).
  - Next: Calibration.
  - Sliders are compact Lightroom-style rows: name, slim track with a mark at the default and the change filled in, then the value (bold when changed). Double-click the name to reset, click the value to type one. Temp, Tint, Vibrance, Saturation and the HSL sliders have colored tracks; Temp moves in perceptual (logarithmic) steps.
- Zoom in loupe and develop: Fit, Fill, 100% (one photo pixel per screen pixel) and 200% in the bar under the photo; Z or a click toggles Fit and 100% at the clicked point; pinch, or ⌥/⌘ and scroll, zooms freely; drag to pan; View > Zoom In (⌘=), Zoom Out (⌘-), Zoom to Fit (⌘0). Zoom is kept when moving between photos.
- Right-click a photo in the grid, loupe or develop for: Open in Loupe, Edit in Develop, zoom levels, Show in Finder, Set Rating, Set Flag, Set Color Label, Develop Settings (Copy, Paste, Reset), Add to Collection, Remove from this collection or import, Write XMP Metadata, Export. Right-clicking an unselected grid photo selects it first.
- Masks (built Oct 27, 2026; see Masking under User experience principles): linear gradient, radial gradient, brush, luminance range and Select Subject (Vision), combined with add, subtract and intersect, each mask with its own local adjustments. Still to come: color range, and AI masks for sky, background and person from Core ML.
- Crop & Straighten (R, or the crop button in the tool strip under the histogram): drag corners and edges to crop, inside the frame to move, outside to straighten; rule-of-thirds grid while dragging, a finer grid while rotating. The panel has an aspect picker (Original, 1 × 1, 4 × 5, 5 × 7, 2 × 3, 3 × 4, 16 × 10, 16 × 9, Free), a swap button (or X) and a lock, an Angle slider (±45°), rotate left and right (⌘[ and ⌘]), flip horizontal and vertical, Reset and Done (Return). Straightening shrinks the frame so it never shows past the photo's edge. The crop applies to previews, exports, Edit In and AI.
- History: unlimited undo per photo; named snapshots; virtual copies share one original. Every change is a named step (Exposure +0.60, Straighten 4.0°, Preset: Punchy, Import Preset: name) listed in the Develop sidebar; click a step to go back to it, Edit > Undo (⌘Z) and Redo (⇧⌘Z) step through it, and Clear History keeps the current look. Snapshots save the current look by name and can be applied, updated with the current settings, renamed and deleted. History and snapshots are stored with the photo.
- Presets: save any subset of settings; apply on import, by drag, or by batch sync. The Develop sidebar lists presets in groups (built-in Atelier looks plus the user's own); click one to apply it. New Preset (the + button) asks for a name, a group and which settings to include, like Lightroom. Right-click a photo > Apply Develop Preset applies to the whole selection; the Import dialog's Apply During Import picks a preset for new photos, whose previews are then rendered with it.
- Copy and paste settings with a checkbox picker; auto-sync across a selection.
- Before and after, chosen from a bar under the photo or with Y: side by side, a slider you drag across the photo (original on the left, edit on the right), and a full toggle with \.
- Color management: soft-proofing for sRGB web output and print profiles.
- Artwork profile: a DCP-style profile built from a ColorChecker shot, applied to all artwork photos for consistent color.

### Settings and keyboard

Atelier > Settings… (⌘,) has these tabs:
- **General:** catalog location (Show in Finder), photo count, backups kept on quit (default 10), Back Up Now, preview cache size.
- **Appearance:** theme, picked from small previews: System (follows macOS), Light, Dark, Graphite (charcoal panels and a dark surround, like Lightroom), Darkroom (near black, so only the photo stands out) and Neutral Gray (a mid-gray surround for judging color and brightness). The theme changes every window at once, Settings included.
- **Import:** default for new imports (leave files or copy into the library folder) and the library folder. The Import dialog starts from these. "Show RAW+JPEG pairs as one photo" (on by default; see RAW+JPEG pairs).
- **Develop:** what a click or Z zooms to (50%, 100%, 200%, 400%), solo mode, and the histogram clipping warnings.
- **Export:** default export folder and whether to show exports in Finder.
- **Edit In:** the external editors and what each is sent (see External editor integration).
- **AI:** the ComfyUI server, models, generation size and workflows (see AI processing).
- **Metadata:** automatically write ratings, flags, labels, keywords, title and caption to XMP sidecars as they change.
- **Keyboard:** every single-key command with its key (Lightroom's by default: 0–5 rating, 6–9 labels, P/X/U flags, G/E/D views, \ before, Y before/after, Z zoom). Click a key and press a new one; a key moves from any action that had it; Delete removes it, Esc cancels; Restore Defaults. Single-key commands only act in the library window, never while typing or in Settings.

Help > Keyboard Shortcuts (⌘/) lists all single-key commands with their current keys plus the menu shortcuts, with a link to change keys.

### Export dialog

File > Export… (⇧⌘E) or the toolbar Export button opens a dialog for the selected photos, or the open photo in loupe and develop. The dialog shows the count on its title and button, offers quick settings (Website: JPEG 2048 px, sRGB, sharpened, no location; Full-Size JPEG; Full-Size TIFF), and remembers the last choices. Exports run in the background with progress and Cancel in the status bar, keep original file names, never replace an existing file (a number is added), write the catalog's keywords, title, caption and rating, and reveal the files in Finder when done. Offline originals are listed as problems instead of stopping the batch.

### Settings format

Develop settings are a JSON document with a schema version, stored in the catalog and mirrored to XMP in a custom namespace. The renderer reads the same JSON, which makes settings diffable, scriptable and portable between catalogs.

## External editor integration

Every outside tool, whether a desktop app or an AI model, plugs in through one **Processor** contract: take a rendered image plus parameters, return an image file. The catalog then stores the result as a new version stacked on the source.

### Edit In (interactive apps)

1. User picks Edit In and an app from a configurable list (Photoshop, Affinity Photo, Pixelmator Pro, GIMP, Krita, any app that opens TIFF).
2. The app renders the photo with current develop settings to the chosen format: 16-bit TIFF (default), PSD, or the original file for apps that read RAW.
3. The file is written next to the original (or to a managed edits folder for read-only volumes) and opened with that app.
4. An FSEvents watcher detects saves and refreshes the preview live.
5. The edited file is cataloged as a version, stacked on top, inheriting metadata and keywords.

Per-app settings: file format, bit depth, color space, resolution, filename template, and whether to apply develop settings first.

As built (Oct 26, 2026):
- Photo > Edit In (the first app is ⌥⌘E) and right-click > Edit In list the installed editors Atelier knows (Photoshop, Affinity Photo, Pixelmator Pro, Photomator, GIMP, Krita), then Other Application…, which adds the chosen app to the list.
- Settings > Edit In edits the list: add any app, rename, remove, Find Installed Editors, and per app the file (16-bit TIFF or JPEG), color space (sRGB, Display P3, Adobe RGB or ProPhoto RGB, the default) and Include develop adjustments.
- The copy is named `<name>-Edit.tif` next to the original, or in Pictures/Atelier/Edits when that folder is read-only. It is cataloged stacked on the original: it sorts right after it, joins the same import entries and collections, and inherits rating, label, title, caption and keywords. Grid badges show "▤ n" on the original and "◪ Edit" on the copy.
- Saves in the editor are picked up by watching the folder (and on switching back to Atelier, and when the photo is shown after a relaunch): the file's size and dimensions are re-read and the previews rebuilt. Edit In on a photo that already is an edit opens it as it is (Lightroom's Edit Original).
- PSD and RAW pass-through wait for v1.

### Processor plugins (headless tools)

For tools without a UI (command-line denoisers, scripts, other AI servers):

- A plugin is a folder with a `manifest.json` (name, version, inputs, parameters schema, output format) and an executable or an HTTP endpoint.
- The app runs it as a sandboxed child process (stdin/stdout JSON) or calls the endpoint, passing file paths and parameters.
- Parameters render as an auto-generated form from the JSON schema.
- Progress, cancel and error reporting follow one protocol for every plugin.
- Built-in AI backends (next section) implement the same contract, so a recipe can mix a Photoshop action, a CLI tool and an AI model.

## AI processing

AI runs locally through swappable backends behind the Processor contract. The app owns the UX (masks, prompts, references, versions); backends only turn inputs into pixels.

### Backends

| Backend | Use for | How the app talks to it | Release |
| --- | --- | --- | --- |
| ComfyUI (headless) | Generative edits: object removal, background replace, relight, multi-reference edits | HTTP + WebSocket API, workflow JSON templates with named inputs | MVP |
| Core ML | Fast on-device tasks: subject and sky masks, denoise, upscale | In-process via Vision and Core ML | v1 |
| MLX | Apple Silicon native diffusion and vision-language models | Bundled Python or Swift MLX worker process | v1 |
| Remote HTTP | A model on another machine or a paid API | Same plugin manifest, endpoint URL | Later |

### Starting model set (permissive licenses only)

| Model | Task | License |
| --- | --- | --- |
| Qwen-Image-Edit-2511 (GGUF) | Instruction-based editing, multi-reference | Apache 2.0 |
| FLUX.2 [klein] 4B | Fast edits and generation | Apache 2.0 |
| Ming-Image-0.1-Design | Website banners and text-heavy graphics with transparency | MIT |
| Segment Anything (SAM 2) | Click-to-mask | Apache 2.0 |
| Real-ESRGAN | Upscaling | BSD-3-Clause |

### Requirements

- **Model registry.** Each model entry stores name, version, backend, file paths, size, memory need, and license with an allowed-use flag (commercial, personal, research). The registry is a JSON file the user can edit.
- **License gate.** Exports tagged for the website or shop block versions produced by a non-commercial model and show which model made them. Qwen-Image-2.1, Fibo 2.0 and FLUX.2 [klein] 9B are allowed for experiments only.
- **Recipes.** A recipe is an ordered list of Processor steps with saved parameters (for example, denoise, then remove distractions, then upscale 2x). Recipes run on one photo or a batch queue.
- **Masked compositing.** Generative models regenerate the whole frame. The app composites only the masked region back onto the original, with feathering, so untouched pixels stay identical. Essential for artwork photos.
- **Inputs.** Prompt, negative prompt, mask, up to 4 reference images picked from the catalog, seed, steps, strength.
- **Provenance.** Every AI version records model, version, recipe, seed and prompt in the catalog and in XMP, so any result can be reproduced or audited.
- **Queue.** One GPU job at a time, background priority, cancel, retry, and an estimate per job. The UI stays responsive while a job runs.
- **As built (Oct 26, 2026).** The AI tool in Develop (the wand button in the tool strip, or Photo > Remove Object…, Replace Background…, Upscale…) shows the ComfyUI connection, the three recipes, and Generate with progress and Cancel.
  - Remove Object: paint over what should go (Brush Size, [ and ] to resize, Paint or Erase, Clear) and optionally say what fills it. Only the area around the strokes is sent, at the generation size, so detail stays high; the result is blended back with a grown, feathered mask.
  - Replace Background: Vision finds the subject on the photo (the background to regenerate is tinted), and the prompt describes the new background. The subject's pixels are kept.
  - Upscale: 2× or 4× with a 4× upscale model.
  - Results are 16-bit TIFFs named `<name>-AI <Recipe>.tif` next to the original, stacked on it with a "✦ AI" badge, and record recipe, workflow, checkpoint, prompt, seed, generation size, region and server as provenance. The original never changes.
  - Settings > AI: server address (default http://127.0.0.1:8188) with Connect, the inpainting checkpoint and upscale model picked from what the server has, generation size (768, 1024 or 1536 px), and Show Workflows Folder. The built-in workflows use core ComfyUI nodes only; a workflow saved in API format as remove-object.json, replace-background.json or upscale.json replaces the built-in one, with inputs found by node title (Atelier Image, Atelier Mask, Atelier Prompt, Atelier Sampler, Atelier Checkpoint, Atelier Upscale Model, Atelier Output Scale, Atelier Output).
  - Still to come: model registry, license gate on export, reference images, batch queue.
- **Agent access (later).** An MCP server exposes search, develop and recipe tools so an AI agent can drive the catalog.

## Architecture and tech stack

A native Swift app with three layers; every external tool and AI model sits behind the Processor host, so adding a backend never touches the catalog or UI.

> Diagram (see live doc): App UI (Library, Develop, AI panel, Export) -> Core services (Catalog service, Render engine, Job queue, Processor host) -> Storage (catalog and previews on local SSD; originals on local drives and megham NAS) and Processors (external apps, plugins, AI backends).

AI backends and plugins run as separate processes, so a crash or memory spike in a model cannot take down the app.

| Layer | Choice | Why |
| --- | --- | --- |
| UI | SwiftUI, AppKit for the grid and loupe (NSCollectionView, Metal-backed views) | SwiftUI alone struggles with 100k-item grids |
| Catalog | SQLite via GRDB, WAL mode | Fast, embeddable, observable queries for live UI |
| RAW and render | Core Image (CIRAWFilter) on Metal, custom Metal kernels for masks and curves | Apple's RAW engine, GPU throughout |
| Masks | Vision (subject, person), Core ML (sky, SAM 2 port) | On-device, no Python for common masks |
| Metadata | ImageIO for EXIF and XMP; Exiv2 for formats ImageIO misses | Broad read and write coverage |
| File watching | FSEvents; security-scoped bookmarks | Sandbox-safe access to drives and NAS |
| AI bridge | URLSession + WebSocket client for ComfyUI; XPC or child process for MLX workers | Process isolation |
| Plugins | JSON manifest + child process (stdin/stdout JSON) or HTTP | Language-agnostic |
| Concurrency | Swift structured concurrency, actors for the catalog and job queue | Safe background work |

## Data model and storage

The catalog is one SQLite database (WAL mode) in a `.atelier` package on the local SSD, never on the NAS. Previews live beside it in a sharded cache folder.

| Entity | Key fields | Notes |
| --- | --- | --- |
| Volume | id, uuid, name, kind (local, NAS), last seen, online | Matched by volume UUID, not mount path |
| Folder | id, volume id, relative path | Mirrors disk |
| Asset | id, folder id, filename, content hash, perceptual hash, capture time, camera, lens, dimensions | One per original file |
| Version | id, asset id, kind (develop, virtual copy, external edit, AI), parent version id, file path (if rendered), created at | Forms the stack |
| DevelopSettings | version id, schema version, JSON, history JSON | Parameters only, no pixels |
| Mask | id, version id, kind, parameters or bitmap path | AI masks cached as 8-bit PNG |
| Metadata | asset id, rating, flag, label, title, caption, GPS | Synced to XMP |
| Keyword / Collection | id, name, parent id; join tables to assets | Hierarchical |
| ImportGroup | id, name, created at; join table to assets | One per import entry; deleting it keeps the photos |
| Processor | id, kind (app, plugin, backend), manifest JSON | External apps and AI backends |
| Model | id, processor id, name, version, license, allowed use, paths | The model registry |
| Job | id, version id, recipe JSON, model id, seed, status, timings, error | Also the provenance record |

Backups: the catalog is snapshotted on quit (keep the last 10) and can be copied to the NAS. XMP sidecars are the recovery path if the catalog is lost.

## Non-functional requirements

Targets assume an M4 Mac and a catalog of 100k photos. They are starting targets to validate in the MVP, not measured figures.

| Area | Requirement |
| --- | --- |
| Grid performance | Scroll 100k thumbnails without dropped frames; filter results in under 200 ms; opening a folder or import shows cached thumbnails immediately, and missing ones load asynchronously, on-screen first |
| Import | Catalog and thumbnail 1,000 RAW files in under 3 minutes from local SSD; NAS imports never block the UI |
| Develop | Slider changes reflect in under 50 ms on the proxy; loupe opens in under 300 ms from preview cache |
| AI jobs | Run in a separate process; a crash or out-of-memory never takes down the app or corrupts the catalog |
| Data safety | Originals are read-only; catalog writes are transactional; hash-verified copies on import |
| Privacy | No network calls except NAS, user-configured backends and update checks; no telemetry |
| Sandboxing | App Sandbox with security-scoped bookmarks for each volume and folder the user grants |
| Accessibility | Full keyboard workflow for culling; VoiceOver labels on all controls |
| Compatibility | macOS 15 and later, Apple Silicon only |

## Milestones and roadmap

Five phases, each closed by a gate you can test on your own photos. No dates yet; each phase starts only when the previous gate passes. Exception (decided Oct 26, 2026): Phase 1 is built before Phase 0, and the ComfyUI round-trip moves to Phase 3.

1. **Phase 0: Spike.** RAW decode on Metal, ComfyUI round-trip, SQLite catalog prototype.
   - Gate 1: a RAW renders, goes through ComfyUI and returns as a version.
2. **Phase 1: Catalog MVP.** Referenced and copied import, import entries, grid and loupe, ratings, keywords, collections, XMP sidecars.
   - Gate 2: a real shoot (a few hundred photos) from the SSD and one from the NAS cataloged without errors, with folders opening fast. Automated scale tests in CI cover larger catalogs (filtering 20k photos, importing 300 with previews).
3. **Phase 2: Develop basics and Edit In.** Basic panel, crop, history, presets, export presets, Photoshop and Affinity round-trip.
   - Gate 3: one full shoot culled, edited and exported without Lightroom.
4. **Phase 3: AI MVP.** ComfyUI recipes, masked compositing, model registry, license gate on export.
   - Gate 4: a website image with an AI edit passes the license gate.
5. **Phase 4: v1.** Curves, HSL, AI masks, Core ML and MLX backends, plugins, batch queue, offline NAS mode.

Phase 3 depends only on the catalog and Processor host, so it can start in parallel with Phase 2 if AI is the higher priority.

## Risks and open questions

The largest risk is scope: a full develop module at Lightroom parity is years of work for a team, so it is phased and the external-editor path covers gaps meanwhile.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Develop-module scope | MVP slips by months | Ship basic tools first; route advanced edits through Edit In until parity |
| RAW quality vs Adobe | Colors look different from Lightroom | Use Apple's RAW engine plus custom camera profiles; compare on a reference set |
| AI memory on Mac | Large models swap or fail | Quantized GGUF, one job at a time, memory check before a job starts |
| Model license drift | A model's license changes or is misread | Registry stores license per version; gate exports; review on every model update |
| NAS latency | Slow browsing and imports | Previews cached locally; background import; offline mode |
| Sandbox limits | Launching external apps or reading NAS paths fails | Security-scoped bookmarks; test early; fall back to a non-sandboxed build for personal use |

### Open questions

- [ ] How much unified memory does the target Mac have? It decides default model quantization.
- [ ] Import existing Lightroom Classic catalogs (ratings, keywords, collections) in v1, or start fresh?
- [ ] Should XMP sidecars be written automatically or only on demand?
- [ ] Keep ComfyUI as a separately installed dependency, or bundle a managed install?
- [ ] Which external editors are actually installed and used today?
