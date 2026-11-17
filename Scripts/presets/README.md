# Built-in Develop preset qualification

The [built-in preset lookbook](../../Sources/AtelierApp/Help/preset-lookbook.html) is the checked-in visual reference. Each preset has its own heading, best subjects, visible qualities and before/after pair. The prose and fixture choices live in [looks.tsv](looks.tsv). The [Swift recipes](../../Sources/AtelierCore/Develop/Settings/BuiltInPresets.swift) are the source for exact slider values and stable IDs.

## Repeat the review

From the repo root on a Mac with full Xcode and Python with Pillow, NumPy, SciPy and OpenCV installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
render_dir="$(mktemp -d)"
swift run PresetQualification "$render_dir" Scripts/presets/fixtures/*.jpg \
  Sources/AtelierApp/Resources/Splash/splash-eagle.jpg \
  Sources/AtelierApp/Resources/Splash/splash-watercolor.jpg \
  Sources/AtelierApp/Resources/Splash/splash-redwoods.jpg
python3 Scripts/help/make_help_images.py --check-presets-from "$render_dir"
```

The command renders a neutral image and every visible preset at 100% for each scene through `DevelopSession.renderSRGB`. It writes a folder per scene and `presets.json` with names, IDs, parts and exact settings. The same ID names the corresponding JPEG in each scene. The largest edge is 1,200 pixels. Check the matching scene and at least one alternate scene for each changed look. At 100% zoom inspect grain, skin, edges beside bright signs and halos along ridgelines. Look for lost shadow detail and blown-out highlights alongside the intended color changes.

The read-only check verifies coverage and compares all Help images to the checked-in reference. It flags a worst-channel mean absolute RGB error over 3/255 to allow small differences from JPEG encoding and macOS rendering. Local changes such as a narrow halo can fall below that threshold. Inspect those changes in the full-size comparisons. Once the visual result is accepted, refresh the examples and Help search index:

```sh
python3 Scripts/help/make_help_images.py --presets-from "$render_dir"
python3 Scripts/help/build_help_index.py
```

Open `Sources/AtelierApp/Help/preset-lookbook.html` in a browser to review the pairs and pack links. The older `preset_sheets.py` remains useful for portable experiments. Its NumPy approximation omits Glow.

## Fixed photographs

All fixtures are sRGB JPEGs. The new fixtures were resized as needed, color-converted when an embedded profile was present and re-encoded without capture metadata. The Help credit section applies to the resized and edited derivatives too.

| Fixture | What it exercises | Credit |
| --- | --- | --- |
| `portrait.jpg` | Deeper skin, blue fabric, dark hair | [NASA portrait of Jessica Watkins](https://www.nasa.gov/people/jessica-watkins/), public domain |
| `portrait-light.jpg` | Lighter skin, orange fabric, hard specular highlights | [NASA portrait of Eileen Collins via scikit-image](https://scikit-image.org/docs/stable/api/skimage.data.html#skimage.data.astronaut), public domain |
| `landscape.jpg` | Blue sky, clouds, sunlit granite and deep foreground shadow | [Ted Wakabayashi, Tunnel View](https://commons.wikimedia.org/wiki/File:Tunnel_view,_Yosemite.jpg), released into the public domain |
| `street.jpg` | Daylight street, cool glass, warm signs and pale walls | [joshuadf, Market Street](https://commons.wikimedia.org/wiki/File:Market_St_at_Fourth_St_in_San_Francisco_with_streetcar_and_ETI_trolleybus_(2011).jpg), [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| `urban.jpg` | Bright practical lights, colored signage and near-black surroundings | [Carles Tomás Martí, Shinjuku](https://commons.wikimedia.org/wiki/File:A_street_of_Shinjuku_at_night.jpg), [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| `twilight.jpg` | Cool twilight sky and warm street lighting | [salomon10, Paris at blue hour](https://commons.wikimedia.org/wiki/File:Blue_hour_-_Paris.jpg), [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| `product.jpg` | Black product, textured colored backdrop and bright reflections | [Henry Söderlund, Nikon D750](https://commons.wikimedia.org/wiki/File:Nikon_D750_01.jpg), [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/) |
| Atelier splash photos | Forest greens and sunbeams, fine feathers and pale paper washes | Rosh, from Atelier’s bundled examples |

## November 2026 audit

Baseline `4b7adb3` shipped 54 looks. The audit rendered and reviewed all 54 across the fixed scenes and compared the final 45 against their previous recipes. The Help examples use the most relevant available subject. The base images have their own original capture and editing characteristics. This review establishes whether a preset communicates its intended look on these fixtures. Measured film matching would require controlled film captures, scan or print targets, and camera-profile calibration. Across the Shinjuku JPEG, Night City reduced pixels with encoded luma at or above 252/255 from 1.45% to 0.23%. On Market Street, Vivid 100 reduced pixels at or below 3/255 from 0.90% to 0.21%. These are fixture-specific checks for highlight and shadow compression. The 100% crops also showed less dense grain around Tungsten 800T signage and less yellow in the Rich Skin portrait.

| Retired look | Where the job is covered |
| --- | --- |
| Atelier / Warm Film | Gold 200 provides a warm snapshot look with a clearer amber signature. |
| Atelier / Black & White | Neutral gives a plain conversion, and Classic 400 or Silver Gelatin add contrast and character. |
| Black & White / High Contrast | Dark Sky gives the red-filter treatment. Push 400 and Noir cover harsher contrast. |
| Portrait / Warm Portrait | Gold 200 and Rich Skin cover stylized warmth and restrained portrait warmth respectively. |
| Landscape / Vivid Landscape | Vivid Slide covers vivid landscape color. Dramatic Sky and Haze Cut are more focused controls. |
| Street / Gritty | Bleach Bypass gives a hard, low-color look, and Push 400 covers grainy monochrome. |
| Street / Daylight Negative | Copper Negative gives the stronger warm-red and cool-shadow identity. |
| Cinematic / Dark & Moody | Moody Portrait handles the low-key subject treatment and Warm Drama handles color-led exteriors. |
| Vintage & Matte / Dusty Pastel | Pastel 400 handles soft portrait color and Faded Matte handles raised blacks. |

An already selected import preset keeps its old recipe and displays a Retired label. Its ID is reserved. The next import choice removes it from the picker. Copper Negative keeps the former Classic Neg ID. New applications use the revised values. Existing edits store the applied slider settings and remain as edited.

## Research targets

- **Portrait 400, Gold 200 and Vivid 100.** Kodak describes smooth skin color for Portra, warm saturated color and fine grain for Gold, and very fine grain with vivid color for Ektar. The review narrowed Gold’s grain and let Vivid 100 keep more shadow detail than Vivid Slide. [Kodak professional color films](https://www.kodakprofessional.com/photographers/film/color) · [Kodak Gold technical sheet](https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/E7022%20Gold%20tech%20sheet.pdf) · [Kodak Gold 120 FAQ](https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/Kodak%20Professional%20Gold%20120%20FAQs.pdf)
- **Pastel 400 and Vivid Slide.** Fujifilm documents smooth skin and tonal gradation for Pro 400H and high color saturation and fine granularity for Velvia 50. Mint and pink in Pastel 400 are Atelier’s interpretation of a pastel scan. [Fujifilm Pro 400H](https://asset.fujifilm.com/www/us/files/2020-04/12ed29db8d4d8bb45563ecdd668b0894/films_pro-400h_datasheet_01.pdf) · [Fujifilm Velvia 50](https://asset.fujifilm.com/www/mm/files/2025-09/822bcabe30ae45e848d559d2d3532ae1/films_velvia-50_datasheet_01.pdf)
- **Chrome 64.** The historic E-55 sheet describes sharp detail, fine grain and natural reproduction of subtle color. The deeper reds and blues are an editorial interpretation. [Kodak E-55, archived copy](https://it.scribd.com/document/6918329/kodachrome)
- **Tungsten 800T.** CineStill documents the tungsten balance and the halation associated with bright highlights. The revised preset pairs a milder blue cast with red-orange halation in Effects. [CineStill film stock guide](https://cinestillfilm.com/blogs/news/cinestill-film-stock-primer) · [CineStill on remjet](https://help.cinestillfilm.com/hc/en-us/articles/360028874012-What-is-Remjet)
- **Classic 400 and Push 400.** Kodak describes the classic grain and sharp edges of Tri-X. Push 400 adds contrast and noticeably coarser grain as a creative pushed-print interpretation. [Kodak Tri-X 400](https://www.kodak.com/en/still-film/product/professional/tri-x-400-film/)
- **Infrared Glow and Selenium.** Ilford describes dark blue skies and light foliage with an appropriate filter. The preset approximates this from visible colors. Harman describes stronger print blacks and variable toning from cool brown through purplish brown. The revised Selenium uses a subtle plum in the darks. [Ilford SFX 200](https://www.ilfordphoto.com/amfile/file/download/file/1907/product/702/) · [Harman Selenium Toner](https://www.ilfordphoto.com/amfile/file/download/file/585/product/671/)
- **Muted Chrome, Copper Negative and Bleach Bypass.** Fujifilm’s documentary simulation emphasizes muted color with firm shadows. Its classic negative simulation is based on everyday negative film. Its bleach-bypass reference emphasizes low saturation and a harder tonal scale. Atelier sets its own curves and color choices. [Fujifilm film simulations](https://www.fujifilm-x.com/en-us/stories/beginner-month-4-camera-features-13-film-simulation-modes/) · [Fujifilm on bleach bypass](https://www.fujifilm-x.com/en-us/stories/tales-of-the-x-t4-tale-3-eterna-bleach-bypass/)

Generic portrait, landscape, street and vintage recipes were assessed against their named visual purpose. Vintage eras, expired film, instant prints and cross-processing vary with stock, lighting, chemistry and output. The lookbook defines which interpretation Atelier ships.
