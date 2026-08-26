from pathlib import Path
import math, wave, struct, random

ROOT=Path(__file__).resolve().parent/'Resources'
MODELS=ROOT/'Models'; AUDIO=ROOT/'Audio'; TEXTURES=ROOT/'Textures'
for p in (MODELS,AUDIO,TEXTURES): p.mkdir(parents=True,exist_ok=True)

class Mesh:
    def __init__(self): self.v=[]; self.f=[]
    def vert(self,x,y,z): self.v.append((x,y,z)); return len(self.v)
    def tri(self,a,b,c): self.f.append((a,b,c))
    def quad(self,a,b,c,d): self.tri(a,b,c); self.tri(a,c,d)
    def box(self,sx,sy,sz,cx=0,cy=0,cz=0):
        x=sx/2;y=sy/2;z=sz/2
        q=[self.vert(cx+dx*x,cy+dy*y,cz+dz*z) for dx,dy,dz in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
        for a,b,c,d in [(0,1,2,3),(4,7,6,5),(0,4,5,1),(1,5,6,2),(2,6,7,3),(4,0,3,7)]: self.quad(q[a],q[b],q[c],q[d])
    def cylinder(self,r,h,cx=0,cy=0,cz=0,n=24,axis='z'):
        rings=[]
        for side in (-1,1):
            ring=[]
            for i in range(n):
                a=2*math.pi*i/n;u=r*math.cos(a);v=r*math.sin(a);w=side*h/2
                if axis=='z': p=(cx+u,cy+v,cz+w)
                elif axis=='y': p=(cx+u,cy+w,cz+v)
                else: p=(cx+w,cy+u,cz+v)
                ring.append(self.vert(*p))
            rings.append(ring)
        for i in range(n): self.quad(rings[0][i],rings[0][(i+1)%n],rings[1][(i+1)%n],rings[1][i])
        c0=self.vert(cx,cy,cz-h/2 if axis=='z' else cz); c1=self.vert(cx,cy,cz+h/2 if axis=='z' else cz)
        if axis=='z':
            for i in range(n): self.tri(c0,rings[0][(i+1)%n],rings[0][i]); self.tri(c1,rings[1][i],rings[1][(i+1)%n])
    def cone(self,r,h,cx=0,cy=0,cz=0,n=20,axis='z',flip=False):
        ring=[]
        for i in range(n):
            a=2*math.pi*i/n;u=r*math.cos(a);v=r*math.sin(a)
            if axis=='z': p=(cx+u,cy+v,cz-h/2)
            elif axis=='x': p=(cx-h/2,cy+u,cz+v)
            else: p=(cx+u,cy-h/2,cz+v)
            ring.append(self.vert(*p))
        if axis=='z': tip=self.vert(cx,cy,cz+h/2)
        elif axis=='x': tip=self.vert(cx+h/2,cy,cz)
        else: tip=self.vert(cx,cy+h/2,cz)
        center=self.vert(cx,cy,cz-h/2 if axis=='z' else cz)
        for i in range(n): self.tri(ring[i],ring[(i+1)%n],tip); self.tri(center,ring[(i+1)%n],ring[i])
    def sphere(self,r,cx=0,cy=0,cz=0,lat=10,lon=18,scale=(1,1,1)):
        grid=[]
        for j in range(lat+1):
            t=math.pi*j/lat;row=[]
            for i in range(lon):
                p=2*math.pi*i/lon
                x=r*math.sin(t)*math.cos(p)*scale[0];y=r*math.cos(t)*scale[1];z=r*math.sin(t)*math.sin(p)*scale[2]
                row.append(self.vert(cx+x,cy+y,cz+z))
            grid.append(row)
        for j in range(lat):
            for i in range(lon): self.quad(grid[j][i],grid[j][(i+1)%lon],grid[j+1][(i+1)%lon],grid[j+1][i])
    def save(self,name):
        with open(MODELS/name,'w') as f:
            f.write('# BREAKROOM MR generated original mesh\n')
            for x,y,z in self.v: f.write(f'v {x:.6f} {y:.6f} {z:.6f}\n')
            for a,b,c in self.f: f.write(f'f {a} {b} {c}\n')

def longsword():
    m=Mesh();m.box(.055,.015,.76,cz=.42);m.cone(.045,.18,cz=.88,n=4);m.box(.31,.04,.045,cz=.035);m.cylinder(.03,.25,cz=-.12);m.sphere(.06,cz=-.28,lat=8,lon=16);m.save('longsword.obj')
def katana():
    m=Mesh();
    for i in range(10): m.box(.043,.012,.105,cx=(i/9)**2*.06,cz=.10+i*.092)
    m.cylinder(.11,.026,cz=.04,n=32);m.cylinder(.028,.31,cz=-.14,n=24);m.save('katana.obj')
def axe():
    m=Mesh();m.cylinder(.034,.82,cz=.14,n=24);m.box(.38,.10,.18,cz=.54);m.cone(.19,.18,cx=.25,cz=.54,n=3,axis='x');m.cone(.07,.20,cx=-.28,cz=.54,n=16,axis='x');m.save('axe.obj')
def warhammer():
    m=Mesh();m.cylinder(.036,.78,cz=.12,n=24);m.box(.43,.18,.19,cz=.54);m.box(.13,.22,.22,cx=.26,cz=.54);m.cone(.09,.28,cx=-.34,cz=.54,n=18,axis='x');m.save('warhammer.obj')
def staff():
    m=Mesh();m.cylinder(.029,1.28,cz=.30,n=24);m.sphere(.08,cz=.98,lat=10,lon=20);m.cylinder(.065,.035,cz=.91,n=32);m.cylinder(.065,.035,cz=-.31,n=32);m.save('staff.obj')
def shield():
    m=Mesh();m.cylinder(.35,.06,cz=.08,n=48);m.sphere(.12,cz=.14,lat=10,lon=20,scale=(1,1,.5));m.cylinder(.025,.30,cz=-.03,n=20,axis='y');m.save('shield.obj')
def spear():
    m=Mesh();m.cylinder(.027,1.48,cz=.31,n=22);m.cone(.09,.30,cz=1.19,n=18);m.cone(.05,.16,cz=-.48,n=16);m.save('spear.obj')
def mace():
    m=Mesh();m.cylinder(.032,.66,cz=.08,n=22);m.sphere(.13,cz=.49,lat=10,lon=20)
    for i in range(8):
        a=2*math.pi*i/8;m.cone(.03,.16,cx=.18*math.cos(a),cy=.18*math.sin(a),cz=.49,n=10)
    m.save('mace.obj')
def enemy_parts():
    h=Mesh();h.sphere(.19,lat=14,lon=28,scale=(1,.94,1.08));h.box(.25,.06,.09,cy=-.15);h.cone(.05,.24,cx=.15,cz=.15,n=16);h.cone(.05,.24,cx=-.15,cz=.15,n=16);h.save('enemy_helmet.obj')
    c=Mesh();c.box(.47,.23,.47);c.box(.35,.065,.33,cy=-.14,cz=.03);c.sphere(.065,cy=-.16,cz=.04,lat=8,lon=16);c.sphere(.13,cx=.30,cz=.08,lat=8,lon=16,scale=(1.3,.8,.7));c.sphere(.13,cx=-.30,cz=.08,lat=8,lon=16,scale=(1.3,.8,.7));c.save('enemy_chest.obj')
    b=Mesh();b.cylinder(.077,.31,n=22);b.box(.035,.18,.24,cy=-.075);b.save('enemy_bracer.obj')

def save_wav(name,samples,sr=22050):
    with wave.open(str(AUDIO/name),'wb') as w:
        w.setnchannels(1);w.setsampwidth(2);w.setframerate(sr)
        w.writeframes(b''.join(struct.pack('<h',max(-32767,min(32767,int(x*32767)))) for x in samples))
def tone(freq,dur,amp=.5,sr=22050):
    n=int(sr*dur);return [math.sin(2*math.pi*freq*i/sr)*amp*((1-i/n)**2) for i in range(n)]
def noise(dur,amp=.4,seed=1,sr=22050):
    rng=random.Random(seed);n=int(sr*dur);return [(rng.random()*2-1)*amp*((1-i/n)**1.7) for i in range(n)]
def mix(*xs):
    n=max(map(len,xs));o=[0.0]*n
    for a in xs:
        for i,v in enumerate(a):o[i]+=v
    m=max(1,max(abs(v) for v in o));return [v/m*.9 for v in o]
def sounds():
    save_wav('swing.wav',mix(noise(.18,.45,1),tone(120,.18,.25)))
    save_wav('metal_hit.wav',mix(tone(820,.30,.65),tone(1210,.22,.3),noise(.08,.2,2)))
    save_wav('body_hit.wav',mix(tone(85,.18,.6),noise(.12,.35,3)))
    save_wav('parry.wav',mix(tone(990,.35,.6),tone(1540,.18,.28),noise(.06,.22,4)))
    save_wav('grab.wav',mix(tone(280,.08,.55),tone(560,.05,.24)))
    save_wav('whoosh.wav',noise(.22,.3,6))
    save_wav('enemy_spawn.wav',mix(tone(110,.45,.25),tone(220,.35,.18),noise(.1,.12,7)))
    save_wav('enemy_down.wav',mix(tone(70,.38,.6),noise(.28,.4,8)))
    save_wav('round_start.wav',mix(tone(440,.18,.35),tone(660,.18,.35),tone(880,.22,.32)))
    save_wav('round_end.wav',mix(tone(660,.18,.35),tone(440,.3,.35)))
    save_wav('dodge.wav',mix(tone(520,.08,.28),tone(780,.11,.22)))
    save_wav('shield.wav',mix(tone(620,.24,.55),noise(.05,.16,10)))
def texture(name,base,seed):
    rng=random.Random(seed);w=h=512;data=bytearray()
    for y in range(h):
        for x in range(w):
            grain=int(18*math.sin(x*.17)+10*math.sin(y*.11)+rng.randint(-12,12))
            data.extend(bytes(max(0,min(255,c+grain)) for c in base))
    with open(TEXTURES/name,'wb') as f:f.write(f'P6\n{w} {h}\n255\n'.encode());f.write(data)

for fn in (longsword,katana,axe,warhammer,staff,shield,spear,mace): fn()
enemy_parts();sounds();texture('enemy_metal.ppm',(62,68,76),2);texture('weapon_metal.ppm',(125,130,136),4)
print('BREAKROOM Giant assets generated:',sum(p.stat().st_size for p in ROOT.rglob('*') if p.is_file()),'bytes')
