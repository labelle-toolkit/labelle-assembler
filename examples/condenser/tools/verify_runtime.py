"""Native deterministic integration captures; requires a built condenser.

Runs the actual keyboard-control branch through frame-60 environment hooks.
Every mode starts a fresh process, uses fixed dt, and captures at two seconds.
"""
from pathlib import Path
import os
import subprocess
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'.test-output/runtime'
OUT.mkdir(parents=True,exist_ok=True)
EXE=ROOT/'.labelle/bgfx_desktop/zig-out/bin/condenser.exe'
MODES={
    'default':{},
    'left_water':{'CONDENSER_TEST_CONTROL':'water'},
    'left_fog':{'CONDENSER_TEST_CONTROL':'fog'},
    'left_lamp':{'CONDENSER_TEST_CONTROL':'lamp'},
    'left_all':{'CONDENSER_TEST_LEFT':'1'},
    'fog_off':{'CONDENSER_FOG_OFF':'1'},
    'lamp_off':{'CONDENSER_LAMP_OFF':'1'},
    'both_off':{'CONDENSER_FOG_OFF':'1','CONDENSER_LAMP_OFF':'1'},
    'zero_width':{'CONDENSER_LAMP_WIDTH':'0'},
    'zero_fog_opacity':{'CONDENSER_FOG_OPACITY':'0'},
}
images={}
for mode,changes in MODES.items():
    env={k:v for k,v in os.environ.items() if not k.startswith('CONDENSER_')}
    env.update(LABELLE_HEADLESS='1',LABELLE_HEADLESS_SURFACELESS='0',LABELLE_HEADLESS_TICKS='180',
               LABELLE_HEADLESS_UNCAPPED='1',LABELLE_FIXED_DT='0.016666667',
               LABELLE_SCREENSHOT_PATH=str(OUT/f'{mode}.tga'),LABELLE_SCREENSHOT_AFTER_SEC='2')
    env.update(changes)
    result=subprocess.run([str(EXE)],cwd=ROOT,env=env,capture_output=True,timeout=60,
                          creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    log=(result.stdout+result.stderr).decode('utf-8',errors='replace')
    (OUT/f'{mode}.log').write_text(log,encoding='utf-8')
    assert result.returncode==0,(mode,result.returncode,log[-3000:])
    for component in ['water_shader.WaterShader','fog_shader.FogShader','lamp_shader.LampShader']:
        assert f'{component}: 2/2 generic materials live' in log,(mode,component,log[-3000:])
    assert '[condenser] water material: TextureNotReady' not in log,(mode,'unexpected startup ERROR')
    image=Image.open(OUT/f'{mode}.tga').convert('RGB')
    assert image.size==(1236,330),(mode,image.size)
    image.save(OUT/f'{mode}.png')
    images[mode]=np.asarray(image)
    print(mode,'clean exit, six live materials, captured',flush=True)

base=images['default']
report=[]
for mode in ['left_water','left_fog','left_lamp','left_all']:
    assert np.array_equal(base[:,618:],images[mode][:,618:]),(mode,'right instance changed')
    changed=np.any(base[:,:618]!=images[mode][:,:618],axis=2)
    assert changed.any(),(mode,'left control had no rendered effect')
    report.append(f'{mode}: {changed.sum()} changed left pixels; right half byte-identical')
assert np.array_equal(images['zero_width'],images['lamp_off']),'width zero must disable source and halo'
assert np.array_equal(images['zero_fog_opacity'],images['fog_off']),'opacity zero must fully remove veil'
assert not np.array_equal(images['fog_off'],images['both_off']),'lamp must work with fog off'
assert not np.array_equal(images['lamp_off'],images['both_off']),'fog must work with lamp off'
report.append('10 native runs; independent fog/lamp off, zero width, zero opacity verified.')
(OUT/'results.txt').write_text('\n'.join(report)+'\n')
print('\n'.join(report))
