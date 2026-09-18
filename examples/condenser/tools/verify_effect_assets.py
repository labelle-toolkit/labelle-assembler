"""CPU reference checks of saved masks, independent controls, and descriptors.
Writes an inspection sheet to .test-output; this is not a GPU screenshot test.
"""
from pathlib import Path
import json
import re
import unittest
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
FOG = np.array([.48, .65, .73])
LAMP = np.array([.64, .85, .94])
Y, X = np.mgrid[:330, :618]
CX, CY = (X // 6 + .5) * 6, (Y // 6 + .5) * 6

def load(path):
    return np.asarray(Image.open(ROOT / path).convert('RGBA')).astype(float) / 255

def footprint(width=348, up=12, down=132, intensity=1, spread=0, softness=6, falloff=2, glow=1, flicker=0, lamp_phase=0):
    reach = np.where(CY < 12, up, down)
    edge=width/2+spread*abs(CY-12)/np.maximum(reach,.001)-abs(CX-309)
    h=(edge>=0).astype(float) if softness==0 else np.clip(edge/softness,0,1)
    v = np.where(reach > 0, np.clip(1-abs(CY-12)/np.maximum(reach, .001), 0, 1), 0)
    valid=(width>0)&(reach>0)&(abs(CY-12)<reach)
    flicker_factor=1-flicker*(.5+.5*np.sin(lamp_phase*2*np.pi))
    source_edge=width/2-abs(CX-309)
    source_h=(source_edge>=0).astype(float) if softness==0 else np.clip(source_edge/softness,0,1)
    return h * v**falloff * valid * intensity * glow * flicker_factor, source_h*(width>0)*min(intensity*flicker_factor,1)

def render(fog_on=True, lamp_on=True, width=348, up=12, down=132, coupling=.35, phase=0, variation=0,
           opacity=1,density=1,wisp_size=48,turbulence=.25,drift=(0,0),**lamp_options):
    ci = load('assets/effects/interior_clean.png')
    cf = load('assets/effects/frame_clean.png')
    fm = load('assets/effects/fog_mask.png')
    lm = load('assets/effects/lamp_mask.png')
    original_frame = load('assets/layers/frame_foreground.png')
    light,h = footprint(width,up,down,int(lamp_on),**lamp_options)
    baseline,_ = footprint()
    a = np.clip(fm[:,:,1]*light,0,1)[:,:,None]
    lit = ci[:,:,:3]*(1-a)+LAMP*a
    scatter=(light-baseline)*coupling
    fc=np.clip(FOG+LAMP*scatter[:,:,None],0,1)
    px=(CX/max(wisp_size,.001)-drift[0])*2*np.pi
    py=(CY/max(wisp_size,.001)-drift[1])*2*np.pi
    noise=(1-turbulence)*np.sin(px)*np.cos(py)+turbulence*np.sin(2*px+phase*2*np.pi)*np.cos(2*py-phase*2*np.pi)
    if wisp_size==0: noise=np.zeros_like(CX)
    amount=density*(1+variation*noise)*int(fog_on)
    veil=np.clip((1-np.maximum(1-fm[:,:,0],.001)**amount)*opacity,0,.95)[:,:,None]
    interior=np.dstack((lit*(1-veil)+fc*veil,ci[:,:,3]))
    a=np.clip(lm[:,:,0]*light,0,1)[:,:,None]
    frame=cf[:,:,:3]*(1-a)+LAMP*a
    emission=(lm[:,:,1]*h*int(lamp_on))[:,:,None]
    frame=frame*(1-emission)+original_frame[:,:,:3]*emission
    frame=np.dstack((frame,cf[:,:,3]))
    canvas=np.zeros((330,618,3))
    for layer in [interior,load('assets/layers/reservoir_static.png'),load('assets/layers/cooler_foreground.png'),frame]:
        alpha=layer[:,:,3:4]
        canvas=canvas*(1-alpha)+layer[:,:,:3]*alpha
    return canvas,interior,frame

class Effects(unittest.TestCase):
    def test_saved_masks_reconstruct_interior_without_double_haze(self):
        _,interior,_=render()
        original=load('assets/layers/machine_interior.png')
        visible=original[:,:,3]>0
        self.assertLessEqual(np.max(abs(interior[:,:,:3][visible]-original[:,:,:3][visible]))*255,2)

    def test_mask_dimensions_alpha_and_foreground_are_preserved(self):
        for stem,source in [('interior','machine_interior'),('frame','frame_foreground')]:
            clean=load(f'assets/effects/{stem}_clean.png')
            art=load(f'assets/layers/{source}.png')
            self.assertEqual(clean.shape,(330,618,4))
            np.testing.assert_array_equal(clean[:,:,3],art[:,:,3])
        fm=load('assets/effects/fog_mask.png')
        self.assertTrue(np.all(fm[:,:,0][fm[:,:,3]==0]==0))

    def test_fog_off_leaves_lamp_control_independent(self):
        _,lit,_=render(fog_on=False)
        _,dark,_=render(fog_on=False,lamp_on=False)
        self.assertGreater(np.max(abs(lit-dark)),.01)
        np.testing.assert_array_equal(dark,load('assets/effects/interior_clean.png'))

    def test_lamp_off_removes_emissive_tube_and_never_restores_outside_mask(self):
        _,_,dark=render(lamp_on=False)
        clean=load('assets/effects/frame_clean.png')
        np.testing.assert_array_equal(dark,clean)
        _,_,lit=render()
        tube=load('assets/effects/lamp_mask.png')[:,:,1]>0
        self.assertGreater(np.mean(lit[:,:,:3][tube]-dark[:,:,:3][tube]),.15)
        _,_,zero=render(width=0)
        np.testing.assert_array_equal(zero,clean)

    def test_fog_scattering_tracks_lamp_and_zero_coupling_is_honored(self):
        _,coupled,_=render(lamp_on=False,coupling=.35)
        _,uncoupled,_=render(lamp_on=False,coupling=0)
        self.assertGreater(np.max(abs(coupled-uncoupled)),.001)

    def test_asymmetric_reaches_and_grid_alignment(self):
        a,_=footprint(up=0,down=132)
        self.assertTrue(np.all(a[CY<12]==0))
        self.assertGreater(a[CY>12].max(),0)
        b,_=footprint(up=12,down=0)
        self.assertTrue(np.all(b[CY>12]==0))
        self.assertGreater(b[CY<12].max(),0)
        np.testing.assert_array_equal(a.reshape(55,6,103,6),np.broadcast_to(a[::6,::6][:,None,:,None],(55,6,103,6)))

    def test_fog_opacity_density_wisp_and_turbulence_have_distinct_semantics(self):
        np.testing.assert_array_equal(render(opacity=0)[0],render(fog_on=False)[0])
        np.testing.assert_array_equal(render(density=0)[0],render(fog_on=False)[0])
        self.assertGreater(np.max(abs(render(opacity=.5,density=2)[0]-render()[0])),.001)
        np.testing.assert_array_equal(render(wisp_size=0,variation=.8,phase=.8)[0],render(wisp_size=0,variation=.8,phase=.2)[0])
        a=render(variation=.8,turbulence=0,drift=(.2,0))[0]
        b=render(variation=.8,turbulence=1,drift=(.2,0))[0]
        self.assertGreater(np.max(abs(a-b)),.01)

    def test_lamp_glow_flicker_and_spread(self):
        a,_=footprint(width=60,spread=120)
        b,_=footprint(width=60,spread=0)
        self.assertGreater(np.sum(a),np.sum(b))
        _,_,source=render(glow=0)
        _,_,dark=render(lamp_on=False)
        tube=load('assets/effects/lamp_mask.png')[:,:,1]>0
        self.assertGreater(np.max(abs(source[tube]-dark[tube])),.1)
        a,_=footprint(flicker=1,lamp_phase=.25)
        self.assertTrue(np.all(abs(a)<1e-10))

    def test_static_art_and_atlas_remain_full_resolution(self):
        manifest=json.loads((ROOT/'assets/condenser.json').read_text())
        for name in ['machine_interior.png','frame_foreground.png','cooler_foreground.png']:
            self.assertEqual(manifest['frames'][name]['sourceSize'],dict(w=618,h=330))

    def test_descriptors_use_reserved_automatic_atlas_binding(self):
        channels=dict(scalar=1,vec2=2,vec3=3,vec4=4,mat4=16)
        for name in ['water','fog','lamp','mist']:
            d=json.loads((ROOT/f'materials/{name}/material.json').read_text())
            source=(ROOT/f'materials/{name}/{d["fragment"]}').read_text()
            self.assertIn('uniform vec4 u_material_rect;',source)
            self.assertNotIn('u_water_rect',source)
            self.assertEqual(set(d['targets']),{'spv','glsl','essl','mtl'})
            for p in d['parameters']:
                self.assertNotIn(p['name'],['u_material_rect','s_tex'])
                if 'defaults' in p: self.assertEqual(len(p['defaults']),p['count']*channels[p['kind']])
            for t in d.get('textures', []): self.assertEqual(t['sampler'],'point')

def sheet():
    cases=[('Default reconstruction',{}),('Fog OFF; lamp ON',dict(fog_on=False)),
        ('Fog ON; lamp OFF',dict(lamp_on=False)),('Both OFF',dict(fog_on=False,lamp_on=False)),
        ('Narrow lamp; no down reach',dict(width=120,down=0)),('Animated fog phase 0.5',dict(phase=.5,variation=.18))]
    out=Image.new('RGB',(1236,3*354),(18,22,27))
    draw=ImageDraw.Draw(out)
    for i,(label,args) in enumerate(cases):
        x,y=(i%2)*618,(i//2)*354
        draw.text((x+8,y+5),label,fill='white')
        out.paste(Image.fromarray(np.rint(np.clip(render(**args)[0],0,1)*255).astype(np.uint8)),(x,y+24))
    target=ROOT/'.test-output/effect-controls.png'
    target.parent.mkdir(exist_ok=True)
    out.save(target)
    print('CPU reference contact sheet:',target)

if __name__=='__main__':
    sheet()
    unittest.main()
