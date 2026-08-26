using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace BreakroomMR.Editor
{
    internal static class ProceduralMeshFactory
    {
        const string Folder = "Assets/BreakroomMR/Generated/Meshes";
        static int counter;

        public static void Reset()
        {
            if (AssetDatabase.IsValidFolder(Folder)) AssetDatabase.DeleteAsset(Folder);
            Directory.CreateDirectory(Folder);
            AssetDatabase.Refresh();
            counter = 0;
        }

        public static Mesh Save(Mesh mesh, string label)
        {
            mesh.name = label + "_Mesh";
            string safe = label.Replace('/', '_').Replace('\\', '_').Replace(' ', '_');
            string path = $"{Folder}/{counter++:D4}_{safe}.asset";
            AssetDatabase.CreateAsset(mesh, path);
            return AssetDatabase.LoadAssetAtPath<Mesh>(path);
        }

        public static Mesh Prism(int sides, float length, float topRadius, float bottomRadius)
        {
            var v = new List<Vector3>();
            var t = new List<int>();
            for (int i = 0; i < sides; i++)
            {
                float a = i * Mathf.PI * 2f / sides;
                v.Add(new Vector3(Mathf.Cos(a) * bottomRadius, -length * .5f, Mathf.Sin(a) * bottomRadius));
            }
            for (int i = 0; i < sides; i++)
            {
                float a = i * Mathf.PI * 2f / sides;
                v.Add(new Vector3(Mathf.Cos(a) * topRadius, length * .5f, Mathf.Sin(a) * topRadius));
            }
            for (int i = 0; i < sides; i++)
            {
                int j = (i + 1) % sides;
                t.Add(i); t.Add(j); t.Add(sides + j);
                t.Add(i); t.Add(sides + j); t.Add(sides + i);
            }
            for (int i = 1; i < sides - 1; i++)
            {
                t.Add(0); t.Add(i + 1); t.Add(i);
                t.Add(sides); t.Add(sides + i); t.Add(sides + i + 1);
            }
            return Finalize(v, t);
        }

        public static Mesh Blade(float length, float width, float thickness, float curve)
        {
            float y0 = -length * .5f;
            float y1 = length * .33f;
            float y2 = length * .5f;
            var v = new List<Vector3>
            {
                new Vector3(-width*.5f,y0,0), new Vector3(width*.5f,y0,0),
                new Vector3(width*.38f,y1+curve,0), new Vector3(0,y2+curve,0), new Vector3(-width*.38f,y1,0),
                new Vector3(0,y0,thickness), new Vector3(0,y0,-thickness),
                new Vector3(0,y2+curve,thickness), new Vector3(0,y2+curve,-thickness)
            };
            var t = new List<int>
            {
                0,1,5, 0,6,1, 1,2,7, 1,7,5, 2,3,7, 3,4,7, 4,0,5, 4,5,7,
                1,6,8, 1,8,2, 2,8,3, 3,8,4, 4,8,6, 4,6,0
            };
            return Finalize(v, t);
        }

        public static Mesh AxeHead(float width, float height, float depth)
        {
            Vector2[] p =
            {
                new Vector2(-width*.34f,-height*.50f), new Vector2(width*.22f,-height*.46f),
                new Vector2(width*.52f,-height*.14f), new Vector2(width*.55f,height*.18f),
                new Vector2(width*.34f,height*.52f), new Vector2(-width*.28f,height*.36f)
            };
            var v = new List<Vector3>();
            foreach (var q in p) v.Add(new Vector3(q.x,q.y,-depth*.5f));
            foreach (var q in p) v.Add(new Vector3(q.x,q.y, depth*.5f));
            var t = new List<int>();
            for (int i=1;i<p.Length-1;i++) { t.Add(0);t.Add(i+1);t.Add(i); t.Add(p.Length);t.Add(p.Length+i);t.Add(p.Length+i+1); }
            for (int i=0;i<p.Length;i++)
            {
                int j=(i+1)%p.Length;
                t.Add(i);t.Add(j);t.Add(p.Length+j); t.Add(i);t.Add(p.Length+j);t.Add(p.Length+i);
            }
            return Finalize(v,t);
        }

        public static Mesh ArmorPlate(float width, float height, float depth, float taper)
        {
            float bw=width*.5f, tw=width*.5f*taper, h=height*.5f, d=depth*.5f;
            var v=new List<Vector3>
            {
                new Vector3(-bw,-h,-d),new Vector3(bw,-h,-d),new Vector3(tw,h,-d),new Vector3(-tw,h,-d),
                new Vector3(-bw,-h,d),new Vector3(bw,-h,d),new Vector3(tw,h,d),new Vector3(-tw,h,d)
            };
            var t=new List<int>{0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,1,2,6,1,6,5,0,4,7,0,7,3};
            return Finalize(v,t);
        }

        public static Mesh Shield(float radius, float depth, int sides=18)
        {
            var mesh=Prism(sides,depth,radius*.90f,radius);
            return mesh;
        }

        static Mesh Finalize(List<Vector3> v, List<int> t)
        {
            var m=new Mesh();
            m.SetVertices(v); m.SetTriangles(t,0);
            m.RecalculateNormals(); m.RecalculateTangents(); m.RecalculateBounds();
            return m;
        }
    }
}