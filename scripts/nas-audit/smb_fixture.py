from pathlib import Path
import json,logging,math,struct,time,wave,zipfile,zlib
from impacket import smbserver,smb3structs
from impacket.ntlm import compute_lmhash,compute_nthash
import argparse
parser=argparse.ArgumentParser(description="Localhost-only SMB fixture share for simulator audits")
parser.add_argument('--root',default='/tmp/mango-earmark-smb-fixtures')
parser.add_argument('--original-epub',type=Path)
parser.add_argument('--read-delay',type=float,default=.004)
parser.add_argument('--reuse-fixtures',action='store_true',help='Restart the service without rewriting generated files')
args=parser.parse_args()
root=Path(args.root);root.mkdir(exist_ok=True)
marker=root/'.simulator-smb-audit'
if any(root.iterdir()) and not marker.exists():
 parser.error('Fixture root must be empty or previously created by this audit')
marker.write_text('Generated SMB simulator fixtures only.\n')
def png(w,h,variant=0,compression=-1):
 def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
 rows=b''.join(b'\0'+bytes([y%255,100,180] if variant==0 else [40,y%255,100])*w for y in range(h))
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows,compression))+chunk(b'IEND',b'')
def create_fixtures():
 image=png(400,600)
 with zipfile.ZipFile(root/'Audit Comic v01.cbz','w',compression=zipfile.ZIP_STORED) as z:
  for i in range(8):z.writestr(f'{i+1:03}.png',image)
  z.writestr('transfer-padding.bin',bytes(range(256))*81920)
 with zipfile.ZipFile(root/'Audit Novel v01.epub','w',compression=zipfile.ZIP_STORED) as z:
  z.writestr('mimetype','application/epub+zip')
  z.writestr('META-INF/container.xml',"<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>")
  items=''.join(f"<item id='c{i}' href='ch{i}.xhtml' media-type='application/xhtml+xml'/>" for i in range(24))
  spine=''.join(f"<itemref idref='c{i}'/>" for i in range(24))
  z.writestr('book.opf',f"<package><metadata><title>Audit Novel</title></metadata><manifest>{items}</manifest><spine>{spine}</spine></package>")
  for i in range(24):
   body=''.join(f'<p>Chapter {i+1}, paragraph {j}. The traveler crossed a quiet garden and opened the old gate.</p>' for j in range(45))
   z.writestr(f'ch{i}.xhtml',f"<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter {i+1}</title></head><body><h1>Chapter {i+1}</h1>{body}</body></html>")
 with wave.open(str(root/'Audit Audio.wav'),'wb') as w:
  w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000)
  frame=b''.join(struct.pack('<h',int(100*math.sin(i*.1))) for i in range(48000))
  for _ in range(180):w.writeframesraw(frame)
 (root/'Empty pages').mkdir(exist_ok=True)
 (root/'Empty pages/ComicInfo.xml').write_text('<ComicInfo/>')
 (root/'Image folder').mkdir(exist_ok=True)
 for i in range(8):(root/'Image folder'/f'{i+1:03}.png').write_bytes(image)
 versions=root/'.versions';versions.mkdir(exist_ok=True)
 for variant,name in enumerate(['old','new','grown']):
  page=png(400,600,variant=variant,compression=0)
  with zipfile.ZipFile(versions/f'Comic-{name}.cbz','w',compression=zipfile.ZIP_STORED) as z:
   for i in range(9 if name=='grown' else 8):z.writestr(f'{i+1:03}.png',page)
   z.writestr('padding.bin',bytes(range(256))*61440)
  with wave.open(str(versions/f'Audio-{name}.wav'),'wb') as w:
   w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000)
   frame=b''.join(struct.pack('<h',int(100*math.sin(i*.1+variant*.7))) for i in range(48000))
   for _ in range(181 if name=='grown' else 180):w.writeframesraw(frame)
if args.reuse_fixtures:
 if not all((root/name).exists() for name in ['Audit Comic v01.cbz','Audit Novel v01.epub','Audit Audio.wav']):
  parser.error('Generated base fixtures are missing; start without --reuse-fixtures once')
else:
 create_fixtures()
server=smbserver.SimpleSMBServer(listenAddress='127.0.0.1',listenPort=1445)
server.addShare('AUDIT',str(root))
if args.original_epub:
 book=args.original_epub.resolve(strict=True)
 server.addShare('ORIGINAL',str(book.parent),readOnly='yes')
server.setSMB2Support(True)
server.addCredential('audit',0,compute_lmhash('local-fixture-only'),compute_nthash('local-fixture-only'))
server.setLogFile('/tmp/mango-earmark-smb-server.log')
original=server.getServer().hookSmb2Command(smb3structs.SMB2_READ,lambda *a:None)
def read(*a):
 time.sleep(args.read_delay)
 return original(*a)
server.getServer().hookSmb2Command(smb3structs.SMB2_READ,read)
print('SMB fixture server ready on 127.0.0.1:1445/AUDIT',flush=True)
server.start()
