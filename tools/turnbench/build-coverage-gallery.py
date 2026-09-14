"""Build a local screenshot gallery from the completed browser captures."""
import html
import json
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
folder = root / 'out/turn-coverage-gallery'
folder.mkdir(exist_ok=True)
records = json.loads((folder / 'results.json').read_text())
parts = ['''<!doctype html><html lang="en-GB"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Completed pike coverage screenshots</title>
<style>body{font:17px system-ui;margin:0;background:#f2f5f3;color:#203d34}
header,main{max-width:1500px;margin:auto;padding:24px}header{background:white}
nav a{display:inline-block;padding:10px;color:#176442}section{margin:32px 0}
figure{margin:24px 0;background:white;padding:16px;border:1px solid #cddbd3;border-radius:8px}
img{width:100%;height:auto;display:block}figcaption{padding:12px 0;font-weight:600}
.legend{padding:12px;background:#e7f1eb}.green{color:#387251}.pink{color:#a03457}
</style><header><h1>Completed pike coverage screenshots</h1>
<p>500 × 400 m field. Six intervening rows skipped in every case. Screenshots show the final playback frame.
The direction label describes the first pike turn; the complete CP pattern then fills the block in both directions.</p>
<p class="legend"><span class="green">Green shading = worked area.</span>
<span class="pink">Pink shading = measured missed coverage.</span>
All 14 rows are driven in CP skipped-row order, filling the intervening rows.</p>
<p>Coverage checks cover the whole working block at 0.25 m cell-centre resolution.
This completes the central row block; headland work is not included. No pink means no gaps detected in the working block.</p>
<p>12 m drill: six headlands (72 m). 6 m drill: nine (54 m). PW 100-12: nine (50.4 m).
These are fixed test settings, not minimum headland recommendations. Offline model; not yet in-game validated.</p>
<nav><a href="#drill12">12 m drill</a><a href="#drill6">6 m drill</a><a href="#pw">PW 100-12</a>
<a href="coverage-screenshots.zip" download>Download all screenshots</a></nav></header><main>''']
for title, anchor in [('12 m trailed drill','drill12'),('6 m trailed drill','drill6'),('PW 100-12 / 5.6 m','pw')]:
    parts.append(f'<section id="{anchor}"><h2>{html.escape(title)}</h2>')
    for run in sorted((r for r in records if r['title']==title),key=lambda r:(r['direction']=='long-to-short',r['angle'])):
        metrics = run.get('metrics') or {}
        status = (f"Whole-block gaps: {metrics.get('missedArea', 0):.2f} m². 14 rows / 13 turns."
                  if run['feasible'] else 'No accepted aligned turn — screenshot shows the baseline for diagnosis.')
        label = f"{run['angle']}° — starts {run['direction'].replace('-', ' ')}. {status}"
        file = html.escape(run['file'])
        preset={'drill12':'drill12','drill6':'drill','pw':'plough'}[anchor]
        direction='long' if run['direction']=='long-to-short' else 'short'
        link=f'http://127.0.0.1:56514/?mode=aligned&amp;case=long-pike-12m&amp;block=1&amp;implement={preset}&amp;angle={run["angle"]}&amp;direction={direction}'
        parts.append(f'<figure><figcaption>{html.escape(label)} <a href="{link}" target="_blank">Run this block</a></figcaption><a href="{file}"><img loading="lazy" src="{file}" alt="{html.escape(label)}"></a></figure>')
    parts.append('</section>')
parts.append('</main></html>')
(folder / 'index.html').write_text('\n'.join(parts),encoding='utf-8')
with zipfile.ZipFile(folder / 'coverage-screenshots.zip','w',zipfile.ZIP_DEFLATED) as archive:
    for name in ['index.html','results.json']+[r['file'] for r in records]:
        archive.write(folder / name,name)
print(f'Gallery: {len(records)} screenshots, {folder / "index.html"}')
