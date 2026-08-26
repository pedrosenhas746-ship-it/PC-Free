using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using UnityEditor;
using UnityEngine;

namespace BreakroomMR.Editor
{
    public static class BreakroomBuilder
    {
        const string Root = "Assets/BreakroomMR";
        const string Generated = Root + "/Generated";
        const string PrefabPath = Generated + "/BreakroomMRRoot.prefab";
        const string LuaPath = Root + "/Lua/breakroom.lua.txt";
        const string OutDir = "Build/BreakroomMR";
        static readonly Dictionary<string, Material> Mats = new Dictionary<string, Material>();

        [MenuItem("BREAKROOM MR/Build Android EMRD")]
        public static void CI()
        {
            PrepareGeneratedFolder();
            ProceduralMeshFactory.Reset();
            GenerateMaterials();

            var temp = BuildPrefab();
            AttachLuaBehaviour(temp);
            PrefabUtility.SaveAsPrefabAsset(temp, PrefabPath);
            UnityEngine.Object.DestroyImmediate(temp);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            var importer = AssetImporter.GetAtPath(PrefabPath);
            if (importer == null) throw new Exception("Prefab importer not found");
            importer.assetBundleName = "bundle";
            importer.SaveAndReimport();

            BuildBundle();
            PackageEmrd();
        }

        static void PrepareGeneratedFolder()
        {
            if (AssetDatabase.IsValidFolder(Generated)) AssetDatabase.DeleteAsset(Generated);
            Directory.CreateDirectory(Generated);
            Directory.CreateDirectory(OutDir);
            AssetDatabase.Refresh();
        }

        static void GenerateMaterials()
        {
            MakeMaterial("ArmorRed", new Color(.58f,.018f,.026f), .80f, .46f, 1001);
            MakeMaterial("ArmorBlack", new Color(.035f,.040f,.048f), .68f, .32f, 2002);
            MakeMaterial("Steel", new Color(.30f,.35f,.40f), .96f, .68f, 3003);
            MakeMaterial("EdgeSteel", new Color(.64f,.72f,.80f), 1f, .84f, 4004);
            MakeMaterial("Wood", new Color(.22f,.072f,.024f), .06f, .20f, 5005);
            MakeMaterial("Grip", new Color(.025f,.020f,.018f), .02f, .14f, 6006);
            MakeMaterial("HandBone", new Color(.58f,.62f,.66f), .34f, .44f, 7007);
            MakeMaterial("GlowRed", new Color(.82f,.018f,.012f), .24f, .75f, 8008);
        }

        static Material MakeMaterial(string name, Color baseColor, float metallic, float smoothness, int seed)
        {
            var tex = new Texture2D(1024,1024,TextureFormat.RGB24,true,false) { name = name + "_Surface" };
            var rng = new System.Random(seed);
            var pixels = new Color32[1024*1024];
            byte rr=(byte)(baseColor.r*255), gg=(byte)(baseColor.g*255), bb=(byte)(baseColor.b*255);
            for(int y=0;y<1024;y++)
            for(int x=0;x<1024;x++)
            {
                float scratches=((x*5+y*11+seed)%173<2)?.23f:0f;
                float bands=((x+y)%71<3)?.09f:0f;
                float noise=((float)rng.NextDouble()-.5f)*.20f + scratches + bands;
                pixels[y*1024+x]=new Color32(
                    (byte)Mathf.Clamp(rr*(1+noise),0,255),
                    (byte)Mathf.Clamp(gg*(1+noise),0,255),
                    (byte)Mathf.Clamp(bb*(1+noise),0,255),255);
            }
            tex.SetPixels32(pixels); tex.Apply(true,false);
            string texPath=$"{Generated}/{name}_Surface.asset";
            AssetDatabase.CreateAsset(tex,texPath);

            var shader=Shader.Find("Standard");
            if(shader==null) throw new Exception("Built-in Standard shader unavailable");
            var mat=new Material(shader){name=name};
            mat.mainTexture=tex;
            mat.color=Color.white;
            mat.SetFloat("_Metallic",metallic);
            mat.SetFloat("_Glossiness",smoothness);
            string matPath=$"{Generated}/{name}.mat";
            AssetDatabase.CreateAsset(mat,matPath);
            Mats[name]=mat;
            return mat;
        }

        static GameObject BuildPrefab()
        {
            var root=new GameObject("BreakroomMRRoot");
            var world=NewChild(root,"WorldRoot");
            var hands=NewChild(root,"Hands");
            BuildHand(hands.transform,"L");
            BuildHand(hands.transform,"R");

            var weapons=NewChild(world,"Weapons");
            BuildSword(weapons.transform,"Longsword_01",false,1f);
            BuildSword(weapons.transform,"Katana_01",true,1f);
            BuildAxe(weapons.transform,"Axe_01");
            BuildHammer(weapons.transform,"Warhammer_01");
            BuildSpear(weapons.transform,"Spear_01");
            BuildShield(weapons.transform,"Shield_01");
            BuildBow(weapons.transform,"Bow_01");
            for(int i=0;i<18;i++) BuildArrow(weapons.transform,$"ArrowPool_{i:D2}");

            var enemies=NewChild(world,"Enemies");
            for(int i=0;i<12;i++)
            {
                var e=BuildEnemy(enemies.transform,i);
                e.SetActive(false);
            }

            var fx=NewChild(world,"FX");
            for(int i=0;i<24;i++)
            {
                var shard=Part(fx.transform,$"ImpactShard_{i:D2}",ProceduralMeshFactory.Prism(6,.055f,.007f,.014f),Mats["GlowRed"]);
                var rb=shard.AddComponent<Rigidbody>(); rb.mass=.02f;rb.isKinematic=true;rb.collisionDetectionMode=CollisionDetectionMode.ContinuousDynamic;
                var col=shard.AddComponent<SphereCollider>();col.radius=.018f;
                shard.SetActive(false);
            }
            return root;
        }

        static void BuildHand(Transform parent,string prefix)
        {
            var rig=NewChild(parent.gameObject,prefix+"HandRig");
            var palm=Part(rig.transform,prefix+"PalmPlate",ProceduralMeshFactory.ArmorPlate(.09f,.105f,.020f,.78f),Mats["HandBone"]);
            var pc=palm.AddComponent<BoxCollider>();pc.size=new Vector3(.085f,.024f,.10f);
            var anchor=NewChild(rig,prefix+"GrabAnchor");anchor.transform.localPosition=new Vector3(0,0,.06f);

            int[,] links={
                {0,1},{1,2},{2,3},{3,4},{0,5},{5,6},{6,7},{7,8},{0,9},{9,10},{10,11},{11,12},
                {0,13},{13,14},{14,15},{15,16},{0,17},{17,18},{18,19},{19,20},{5,9},{9,13},{13,17}
            };
            for(int i=0;i<21;i++)
            {
                var m=ProceduralMeshFactory.Prism(8,.018f,.009f,.011f);
                Part(rig.transform,$"{prefix}J{i:D2}",m,(i==4||i==8||i==12||i==16||i==20)?Mats["GlowRed"]:Mats["HandBone"]);
            }
            for(int i=0;i<links.GetLength(0);i++)
            {
                var m=ProceduralMeshFactory.Prism(8,.070f,.0055f,.0075f);
                Part(rig.transform,$"{prefix}B{links[i,0]:D2}_{links[i,1]:D2}",m,Mats["HandBone"]);
            }
        }

        static GameObject BuildEnemy(Transform parent,int index)
        {
            var e=NewChild(parent.gameObject,$"Enemy_{index:D2}");
            var pelvis=Body(e.transform,"Pelvis",.30f,.18f,.20f,new Vector3(0,.93f,0),5f,Mats["ArmorBlack"]);
            var chest=Body(e.transform,"Chest",.43f,.43f,.24f,new Vector3(0,1.25f,0),7f,Mats["ArmorRed"]);
            var head=Body(e.transform,"Head",.25f,.28f,.24f,new Vector3(0,1.62f,0),3f,Mats["ArmorBlack"]);
            var ual=Limb(e.transform,"UpperArm_L",new Vector3(-.30f,1.35f,0),.32f,.079f,2f);
            var lal=Limb(e.transform,"LowerArm_L",new Vector3(-.50f,1.12f,0),.31f,.064f,1.5f);
            var uar=Limb(e.transform,"UpperArm_R",new Vector3(.30f,1.35f,0),.32f,.079f,2f);
            var lar=Limb(e.transform,"LowerArm_R",new Vector3(.50f,1.12f,0),.31f,.064f,1.5f);
            var tl=Limb(e.transform,"Thigh_L",new Vector3(-.11f,.68f,0),.44f,.093f,3f);
            var sl=Limb(e.transform,"Shin_L",new Vector3(-.11f,.28f,0),.40f,.078f,2.5f);
            var tr=Limb(e.transform,"Thigh_R",new Vector3(.11f,.68f,0),.44f,.093f,3f);
            var sr=Limb(e.transform,"Shin_R",new Vector3(.11f,.28f,0),.40f,.078f,2.5f);

            Connect(chest,pelvis,25,25,20); Connect(head,chest,25,35,25);
            Connect(ual,chest,60,45,60);Connect(lal,ual,85,15,15);Connect(uar,chest,60,45,60);Connect(lar,uar,85,15,15);
            Connect(tl,pelvis,55,35,30);Connect(sl,tl,80,12,12);Connect(tr,pelvis,55,35,30);Connect(sr,tr,80,12,12);

            var face=Part(head.transform,"FaceMask",ProceduralMeshFactory.ArmorPlate(.205f,.13f,.042f,.72f),Mats["Steel"]);
            face.transform.localPosition=new Vector3(0,0,.13f);
            var visor=Part(face.transform,"Visor",ProceduralMeshFactory.ArmorPlate(.15f,.032f,.012f,.90f),Mats["GlowRed"]);
            visor.transform.localPosition=new Vector3(0,.018f,.028f);
            var chestPlate=Part(chest.transform,"ChestArmor",ProceduralMeshFactory.ArmorPlate(.44f,.31f,.075f,.72f),Mats["ArmorRed"]);
            chestPlate.transform.localPosition=new Vector3(0,.015f,.14f);
            var waist=Part(pelvis.transform,"WaistArmor",ProceduralMeshFactory.ArmorPlate(.31f,.12f,.07f,.82f),Mats["Steel"]);
            waist.transform.localPosition=new Vector3(0,-.01f,.12f);
            AddShoulder(ual.transform,"Shoulder_L");AddShoulder(uar.transform,"Shoulder_R");

            var weaponAnchor=NewChild(lar,"WeaponAnchor");
            weaponAnchor.transform.localPosition=new Vector3(0,-.17f,.07f);
            weaponAnchor.transform.localRotation=Quaternion.Euler(90,0,0);
            var sword=BuildSword(weaponAnchor.transform,"EnemySword",false,.84f);
            var wrb=sword.GetComponent<Rigidbody>();if(wrb)wrb.isKinematic=true;
            return e;
        }

        static void AddShoulder(Transform arm,string name)
        {
            var p=Part(arm,name,ProceduralMeshFactory.ArmorPlate(.18f,.10f,.18f,.68f),Mats["ArmorRed"]);
            p.transform.localPosition=new Vector3(0,.12f,0);
        }

        static GameObject Body(Transform p,string name,float w,float h,float d,Vector3 pos,float mass,Material mat)
        {
            var go=Part(p,name,ProceduralMeshFactory.ArmorPlate(w,h,d,.72f),mat);go.transform.localPosition=pos;
            var rb=go.AddComponent<Rigidbody>();rb.mass=mass;rb.isKinematic=true;rb.interpolation=RigidbodyInterpolation.Interpolate;
            var c=go.AddComponent<BoxCollider>();c.size=new Vector3(w*.92f,h*.92f,d*.92f);
            return go;
        }

        static GameObject Limb(Transform p,string name,Vector3 pos,float length,float radius,float mass)
        {
            var go=Part(p,name,ProceduralMeshFactory.Prism(8,length,radius*.72f,radius),Mats["ArmorBlack"]);go.transform.localPosition=pos;
            var rb=go.AddComponent<Rigidbody>();rb.mass=mass;rb.isKinematic=true;rb.interpolation=RigidbodyInterpolation.Interpolate;
            var c=go.AddComponent<CapsuleCollider>();c.direction=1;c.height=length;c.radius=radius*.84f;
            return go;
        }

        static void Connect(GameObject a,GameObject b,float x,float y,float z)
        {
            var j=a.AddComponent<ConfigurableJoint>();j.connectedBody=b.GetComponent<Rigidbody>();
            j.xMotion=j.yMotion=j.zMotion=ConfigurableJointMotion.Locked;
            j.angularXMotion=j.angularYMotion=j.angularZMotion=ConfigurableJointMotion.Limited;
            var lo=j.lowAngularXLimit;lo.limit=-x;j.lowAngularXLimit=lo;var hi=j.highAngularXLimit;hi.limit=x;j.highAngularXLimit=hi;
            var yl=j.angularYLimit;yl.limit=y;j.angularYLimit=yl;var zl=j.angularZLimit;zl.limit=z;j.angularZLimit=zl;j.enableCollision=false;
        }

        static GameObject BuildSword(Transform p,string name,bool katana,float scale)
        {
            var w=NewChild(p.gameObject,name);w.transform.localScale=Vector3.one*scale;
            var blade=Part(w.transform,"Blade",ProceduralMeshFactory.Blade(katana?.82f:.76f,katana?.040f:.058f,katana?.006f:.012f,katana?.040f:0),Mats["EdgeSteel"]);blade.transform.localPosition=new Vector3(0,.49f,0);
            var guard=Part(w.transform,"Guard",ProceduralMeshFactory.Prism(10,.25f,.015f,.022f),Mats["Steel"]);guard.transform.localRotation=Quaternion.Euler(0,0,90);guard.transform.localPosition=new Vector3(0,.08f,0);
            var grip=Part(w.transform,"Grip",ProceduralMeshFactory.Prism(10,.23f,.019f,.025f),Mats["Grip"]);grip.transform.localPosition=new Vector3(0,-.08f,0);
            var pommel=Part(w.transform,"Pommel",ProceduralMeshFactory.Prism(8,.07f,.029f,.020f),Mats["Steel"]);pommel.transform.localPosition=new Vector3(0,-.22f,0);
            WeaponPhysics(w,1.25f,new Vector3(.075f,1.12f,.055f),new Vector3(0,.32f,0));return w;
        }

        static GameObject BuildAxe(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);var haft=Part(w.transform,"Haft",ProceduralMeshFactory.Prism(10,.76f,.022f,.032f),Mats["Wood"]);haft.transform.localPosition=new Vector3(0,.18f,0);
            var head=Part(w.transform,"AxeHead",ProceduralMeshFactory.AxeHead(.38f,.26f,.065f),Mats["EdgeSteel"]);head.transform.localPosition=new Vector3(.10f,.57f,0);
            var spike=Part(w.transform,"BackSpike",ProceduralMeshFactory.Blade(.25f,.05f,.025f,0),Mats["Steel"]);spike.transform.localPosition=new Vector3(-.16f,.57f,0);spike.transform.localRotation=Quaternion.Euler(0,0,90);
            WeaponPhysics(w,2.35f,new Vector3(.46f,.91f,.12f),new Vector3(.04f,.24f,0));return w;
        }

        static GameObject BuildHammer(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);var haft=Part(w.transform,"Haft",ProceduralMeshFactory.Prism(10,.74f,.023f,.033f),Mats["Grip"]);haft.transform.localPosition=new Vector3(0,.17f,0);
            var head=Part(w.transform,"HammerHead",ProceduralMeshFactory.ArmorPlate(.42f,.18f,.20f,.92f),Mats["Steel"]);head.transform.localPosition=new Vector3(0,.57f,0);
            var cap=Part(head.transform,"ImpactFace",ProceduralMeshFactory.Prism(12,.14f,.085f,.10f),Mats["EdgeSteel"]);cap.transform.localRotation=Quaternion.Euler(0,0,90);cap.transform.localPosition=new Vector3(.25f,0,0);
            WeaponPhysics(w,3.7f,new Vector3(.62f,.94f,.28f),new Vector3(0,.22f,0));return w;
        }

        static GameObject BuildSpear(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);var shaft=Part(w.transform,"Shaft",ProceduralMeshFactory.Prism(12,1.52f,.017f,.024f),Mats["Wood"]);shaft.transform.localPosition=new Vector3(0,.48f,0);
            var point=Part(w.transform,"SpearPoint",ProceduralMeshFactory.Blade(.36f,.072f,.020f,0),Mats["EdgeSteel"]);point.transform.localPosition=new Vector3(0,1.42f,0);
            WeaponPhysics(w,1.9f,new Vector3(.11f,1.96f,.11f),new Vector3(0,.51f,0));return w;
        }

        static GameObject BuildShield(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);Part(w.transform,"ShieldFace",ProceduralMeshFactory.Shield(.36f,.058f),Mats["ArmorRed"]);
            var boss=Part(w.transform,"ShieldBoss",ProceduralMeshFactory.Prism(12,.11f,.12f,.16f),Mats["Steel"]);boss.transform.localRotation=Quaternion.Euler(90,0,0);boss.transform.localPosition=new Vector3(0,0,.055f);
            var grip=Part(w.transform,"Grip",ProceduralMeshFactory.Prism(10,.20f,.021f,.027f),Mats["Grip"]);grip.transform.localRotation=Quaternion.Euler(90,0,0);grip.transform.localPosition=new Vector3(0,0,-.08f);
            WeaponPhysics(w,2.5f,new Vector3(.74f,.74f,.15f),Vector3.zero);return w;
        }

        static GameObject BuildBow(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);
            for(int i=0;i<10;i++)
            {
                float y=-.56f+i*.125f;float side=(i<5?-1:1);float bend=Mathf.Abs(i-4.5f)*.026f;
                var seg=Part(w.transform,$"Limb_{i:D2}",ProceduralMeshFactory.Prism(8,.14f,.012f,.020f),Mats["Wood"]);
                seg.transform.localPosition=new Vector3(side*bend,y,0);seg.transform.localRotation=Quaternion.Euler(0,0,side*(8+Mathf.Abs(i-4.5f)*4));
            }
            Part(w.transform,"Handle",ProceduralMeshFactory.Prism(10,.24f,.024f,.031f),Mats["Grip"]);
            var line=NewChild(w,"String");var lr=line.AddComponent<LineRenderer>();lr.positionCount=3;lr.startWidth=lr.endWidth=.0035f;lr.useWorldSpace=false;lr.sharedMaterial=Mats["HandBone"];
            lr.SetPosition(0,new Vector3(-.17f,-.62f,0));lr.SetPosition(1,Vector3.zero);lr.SetPosition(2,new Vector3(.17f,.62f,0));
            WeaponPhysics(w,1.05f,new Vector3(.46f,1.34f,.13f),Vector3.zero);return w;
        }

        static GameObject BuildArrow(Transform p,string name)
        {
            var w=NewChild(p.gameObject,name);Part(w.transform,"Shaft",ProceduralMeshFactory.Prism(8,.66f,.0045f,.006f),Mats["Wood"]);
            var tip=Part(w.transform,"Point",ProceduralMeshFactory.Blade(.10f,.028f,.009f,0),Mats["EdgeSteel"]);tip.transform.localPosition=new Vector3(0,.38f,0);
            var rb=w.AddComponent<Rigidbody>();rb.mass=.065f;rb.isKinematic=true;rb.collisionDetectionMode=CollisionDetectionMode.ContinuousDynamic;
            var c=w.AddComponent<CapsuleCollider>();c.direction=1;c.height=.76f;c.radius=.009f;w.SetActive(false);return w;
        }

        static void WeaponPhysics(GameObject w,float mass,Vector3 size,Vector3 center)
        {
            var rb=w.AddComponent<Rigidbody>();rb.mass=mass;rb.interpolation=RigidbodyInterpolation.Interpolate;rb.collisionDetectionMode=CollisionDetectionMode.ContinuousDynamic;
            var c=w.AddComponent<BoxCollider>();c.size=size;c.center=center;
        }

        static GameObject Part(Transform parent,string name,Mesh mesh,Material material)
        {
            var go=new GameObject(name);go.transform.SetParent(parent,false);
            var mf=go.AddComponent<MeshFilter>();mf.sharedMesh=ProceduralMeshFactory.Save(mesh,name);
            var mr=go.AddComponent<MeshRenderer>();mr.sharedMaterial=material;return go;
        }

        static GameObject NewChild(GameObject parent,string name){var go=new GameObject(name);go.transform.SetParent(parent.transform,false);return go;}

        static void AttachLuaBehaviour(GameObject root)
        {
            var lua=AssetDatabase.LoadAssetAtPath<TextAsset>(LuaPath);if(!lua)throw new Exception("Runtime Lua missing: "+LuaPath);
            var type=AppDomain.CurrentDomain.GetAssemblies().SelectMany(a=>{try{return a.GetTypes();}catch{return Type.EmptyTypes;}}).FirstOrDefault(t=>t.Name=="LuaBehaviour"&&typeof(MonoBehaviour).IsAssignableFrom(t));
            if(type==null)throw new Exception("ETMR LuaBehaviour type was not found. SDK import failed.");
            var comp=root.AddComponent(type);var so=new SerializedObject(comp);var it=so.GetIterator();bool assigned=false;
            while(it.NextVisible(true))
            {
                string n=it.name.ToLowerInvariant();
                if(n!="m_script"&&it.propertyType==SerializedPropertyType.ObjectReference&&n.Contains("lua")){it.objectReferenceValue=lua;assigned=true;}
                if(it.propertyType==SerializedPropertyType.Boolean&&n.Contains("callupdate"))it.boolValue=true;
            }
            so.ApplyModifiedPropertiesWithoutUndo();if(!assigned)throw new Exception("LuaBehaviour found, but its Lua TextAsset field could not be assigned.");
        }

        static void BuildBundle()
        {
            string dir=OutDir+"/bundleout";if(Directory.Exists(dir))Directory.Delete(dir,true);Directory.CreateDirectory(dir);
            var result=BuildPipeline.BuildAssetBundles(dir,BuildAssetBundleOptions.ChunkBasedCompression,BuildTarget.Android);if(result==null)throw new Exception("Android AssetBundle build failed");
            string src=dir+"/bundle";if(!File.Exists(src))throw new Exception("Expected bundle file was not produced");File.Copy(src,OutDir+"/bundle",true);
        }

        static void PackageEmrd()
        {
            string json="{\n  \"id\": \"com.pedro.breakroommr\",\n  \"name\": \"BREAKROOM MR\",\n  \"version\": \"0.1.0\",\n  \"author\": \"Pedro\",\n  \"description\": \"Infinite 6DoF mixed-reality melee physics sandbox\",\n  \"entryPrefab\": \"BreakroomMRRoot\",\n  \"display\": \"scene\",\n  \"minApiVersion\": 1,\n  \"type\": \"bundle\",\n  \"permissions\": [\"scene\", \"input\", \"audio\", \"storage\"]\n}";
            File.WriteAllText(OutDir+"/app.json",json);
            string emrd=OutDir+"/BREAKROOM_MR_ANDROID.emrd";if(File.Exists(emrd))File.Delete(emrd);
            using(var zip=ZipFile.Open(emrd,ZipArchiveMode.Create)){zip.CreateEntryFromFile(OutDir+"/app.json","app.json",CompressionLevel.Optimal);zip.CreateEntryFromFile(OutDir+"/bundle","bundle",CompressionLevel.NoCompression);}
            var fi=new FileInfo(emrd);Debug.Log($"BREAKROOM MR EMRD READY: {fi.FullName} ({fi.Length} bytes)");
        }
    }
}