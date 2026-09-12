#!/usr/bin/env python3
"""Create aligned overlay, side-by-side, diff, and metrics for two PNGs."""
import argparse, json
from pathlib import Path
from PIL import Image, ImageChops, ImageEnhance

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--figma', required=True)
    p.add_argument('--actual', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--threshold', type=int, default=16)
    a = p.parse_args(); out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    figma = Image.open(a.figma).convert('RGBA'); actual = Image.open(a.actual).convert('RGBA')
    if figma.size != actual.size:
        raise SystemExit(f'input dimensions differ: figma={figma.size}, actual={actual.size}')
    overlay = Image.blend(figma, actual, 0.5)
    diff = ImageChops.difference(figma, actual)
    heat = ImageEnhance.Contrast(diff.convert('RGB')).enhance(3.0)
    side = Image.new('RGB', (figma.width * 2, figma.height), 'white')
    side.paste(figma.convert('RGB'), (0, 0)); side.paste(actual.convert('RGB'), (figma.width, 0))
    fpx, apx = list(figma.getdata()), list(actual.getdata()); matches = 0; exact = 0; total = len(fpx); sum_delta = 0; max_delta = 0
    for f, q in zip(fpx, apx):
        delta = max(abs(f[i] - q[i]) for i in range(3)); max_delta = max(max_delta, delta); sum_delta += delta
        exact += delta == 0; matches += delta <= a.threshold
    overlay.save(out / 'overlay.png'); heat.save(out / 'diff.png'); side.save(out / 'side-by-side.png')
    (out / 'metrics.json').write_text(json.dumps({'comparison':'raw pixel agreement; not perceptual correctness','dimensions':{'width':figma.width,'height':figma.height},'threshold':a.threshold,'exactPixels':exact,'matchingPixels':matches,'pixelCount':total,'exactPercentage':exact*100/total,'matchPercentage':matches*100/total,'meanMaxRGBDelta':sum_delta/total,'maxRGBDelta':max_delta,'transformations':'none; no scaling, cropping, or masking'}, indent=2)+'\n')
    print(out)
if __name__ == '__main__': main()
