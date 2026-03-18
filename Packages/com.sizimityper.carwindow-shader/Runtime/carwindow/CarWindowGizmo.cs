using UnityEngine;

/// <summary>
/// Editor-only Gizmo visualizer for CarWindow.shader wiper geometry.
/// Attach to the same GameObject as the glass MeshRenderer.
/// Converts glassUV (0-1) to world space via barycentric interpolation of the
/// actual mesh geometry, so non-planar (curved) meshes are supported.
/// Falls back to standard-quad mapping if no MeshFilter is found.
/// </summary>
[ExecuteInEditMode]
public class CarWindowGizmo : MonoBehaviour
{
    public Material targetMaterial;

    [Space]
    [Tooltip("Assign CarWindowWiperSync to bake wiper data for VRChat runtime")]
    public CarWindowWiperSync wiperSync;

    [Header("Timing")]
    public float wiperPeriod   = 2.0f;
    public float wiperInterval = 0.0f;

    [Space]
    public WiperConfig[] wipers = new WiperConfig[4]
    {
        new WiperConfig(),
        new WiperConfig(),
        new WiperConfig(),
        new WiperConfig(),
    };

    // -------------------------------------------------------
    //  Data push (edit time + play time)
    // -------------------------------------------------------
    void OnValidate()   { CacheMesh(); PushToMaterial(); BakeToWiperSync(); }
    void OnDrawGizmos() { CacheMesh(); PushToMaterial(); DrawGizmos(); }
    void Update()       { PushToMaterial(); }  // keeps material correct in editor Play mode

    void PushToMaterial()
    {
        if (targetMaterial == null) return;

        var pivotArm = new Vector4[4];
        var blade    = new Vector4[4];
        var angles   = new Vector4[4];

        for (int i = 0; i < 4; i++)
        {
            WiperConfig w = SafeWiper(i);
            // Both modes use the same pivot/arm/angles layout
            pivotArm[i] = new Vector4(w.pivotPos.x, w.pivotPos.y, w.armLength, w.bladeYOffset);
            angles[i]   = new Vector4(w.armAngleMin, w.armAngleMax, w.enabled ? 1f : 0f, w.direction);
            // Mode 0: bladeAngle=0 → perpendicular-to-arm (add +90° for shader convention)
            // Mode 1: bladeAngle=0 → horizontal in UV space (no offset needed)
            float bladeAngDeg = w.bladeAngle + 90f;
            blade[i] = new Vector4(bladeAngDeg, w.bladeSMin, w.bladeSMax, (float)w.wiperMode);
        }

        targetMaterial.SetVectorArray("_WiperPivotArm", pivotArm);
        targetMaterial.SetVectorArray("_WiperBlade",    blade);
        targetMaterial.SetVectorArray("_WiperAngles",   angles);
        targetMaterial.SetFloat("_WiperPeriod",   Mathf.Max(wiperPeriod,   0.3f));
        targetMaterial.SetFloat("_WiperInterval", Mathf.Max(wiperInterval, 0.0f));
#if UNITY_EDITOR
        UnityEditor.EditorUtility.SetDirty(targetMaterial);
#endif
    }

    void BakeToWiperSync()
    {
        if (wiperSync == null) return;

        wiperSync.bakedPeriod   = Mathf.Max(wiperPeriod,   0.3f);
        wiperSync.bakedInterval = Mathf.Max(wiperInterval, 0.0f);

        for (int i = 0; i < 4; i++)
        {
            WiperConfig w = SafeWiper(i);
            wiperSync.bakedPivotArm[i] = new Vector4(w.pivotPos.x, w.pivotPos.y, w.armLength, w.bladeYOffset);
            wiperSync.bakedAngles[i]   = new Vector4(w.armAngleMin, w.armAngleMax, w.enabled ? 1f : 0f, w.direction);
            float bakedBladeAng = w.bladeAngle + 90f;
            wiperSync.bakedBlade[i] = new Vector4(bakedBladeAng, w.bladeSMin, w.bladeSMax, (float)w.wiperMode);
        }
        wiperSync.bakedReady = true;

#if UNITY_EDITOR
        UnityEditor.EditorUtility.SetDirty(wiperSync);
#endif
    }

    WiperConfig SafeWiper(int i)
    {
        return (wipers != null && i < wipers.Length && wipers[i] != null)
            ? wipers[i] : new WiperConfig();
    }

    // -------------------------------------------------------
    //  Gizmo drawing
    // -------------------------------------------------------
    void DrawGizmos()
    {
        if (targetMaterial == null) return;

        // Per-wiper colours
        Color[] colors = {
            new Color(0.2f, 1.0f, 0.3f),
            new Color(0.3f, 0.6f, 1.0f),
            new Color(1.0f, 0.8f, 0.2f),
            new Color(1.0f, 0.3f, 0.5f),
        };

        for (int i = 0; i < 4; i++)
        {
            WiperConfig w = SafeWiper(i);
            if (!w.enabled) continue;

            Color col = colors[i];

            if (w.wiperMode == WiperMode.Train)
            {
                // --- Parallel crank mode: fan sweep, blade fixed in UV space ---
                float betaFixed = (w.bladeAngle + 90f) * Mathf.Deg2Rad;
                Vector2 bladeDirFixed = new Vector2(Mathf.Cos(betaFixed), -Mathf.Sin(betaFixed));

                // Pivot sphere
                Gizmos.color = col;
                Gizmos.DrawSphere(GlassToWorld(w.pivotPos), 0.008f);

                // Sweep envelope (24 steps, fixed blade direction)
                const int stepsPC = 24;
                for (int st = 0; st <= stepsPC; st++)
                {
                    float t     = (float)st / stepsPC;
                    float theta = Mathf.Lerp(w.armAngleMin, w.armAngleMax, t) * Mathf.Deg2Rad;
                    float sinT  = Mathf.Sin(theta), cosT = Mathf.Cos(theta);
                    Vector2 armTip   = w.pivotPos + new Vector2(sinT,  cosT) * w.armLength;
                    Vector2 bladeCtr = armTip     + new Vector2(cosT, -sinT) * w.bladeYOffset;
                    Gizmos.color = new Color(col.r, col.g, col.b, 0.25f);
                    Gizmos.DrawLine(GlassToWorld(bladeCtr + bladeDirFixed * w.bladeSMin),
                                    GlassToWorld(bladeCtr + bladeDirFixed * w.bladeSMax));
                }

                // Key positions: angleMin (cyan), mid (col), angleMax (white)
                float[] pcAngles = { w.armAngleMin, (w.armAngleMin + w.armAngleMax) * 0.5f, w.armAngleMax };
                Color[]  pcCols  = { Color.cyan, col, Color.white };
                for (int k = 0; k < 3; k++)
                {
                    float theta  = pcAngles[k] * Mathf.Deg2Rad;
                    float sinT   = Mathf.Sin(theta), cosT = Mathf.Cos(theta);
                    Vector2 armTip   = w.pivotPos + new Vector2(sinT,  cosT) * w.armLength;
                    Vector2 bladeCtr = armTip     + new Vector2(cosT, -sinT) * w.bladeYOffset;
                    Gizmos.color = pcCols[k];
                    Gizmos.DrawLine(GlassToWorld(w.pivotPos), GlassToWorld(armTip));
                    Gizmos.DrawSphere(GlassToWorld(bladeCtr), 0.005f);
                    Gizmos.DrawLine(GlassToWorld(bladeCtr + bladeDirFixed * w.bladeSMin),
                                    GlassToWorld(bladeCtr + bladeDirFixed * w.bladeSMax));
                }
            }
            else
            {
                // --- Pivot mode ---
                Gizmos.color = col;
                Gizmos.DrawSphere(GlassToWorld(w.pivotPos), 0.008f);

                const int steps = 24;
                for (int st = 0; st <= steps; st++)
                {
                    float t     = (float)st / steps;
                    float theta = Mathf.Lerp(w.armAngleMin, w.armAngleMax, t) * Mathf.Deg2Rad;
                    Vector2 s = BladeStart(w, theta);
                    Vector2 e = BladeEnd(w, theta);
                    Gizmos.color = new Color(col.r, col.g, col.b, 0.25f);
                    Gizmos.DrawLine(GlassToWorld(s), GlassToWorld(e));
                }

                DrawArmAndBlade(w, w.armAngleMin * Mathf.Deg2Rad, Color.cyan);
                DrawArmAndBlade(w, w.armAngleMax * Mathf.Deg2Rad, Color.white);
                float mid = (w.armAngleMin + w.armAngleMax) * 0.5f * Mathf.Deg2Rad;
                DrawArmAndBlade(w, mid, col);
            }
        }
    }

    void DrawUVBlade(WiperConfig w, Vector2 pos, Color col)
    {
        float beta   = (w.bladeAngle + 90f) * Mathf.Deg2Rad;
        Vector2 bDir = new Vector2(Mathf.Cos(beta), -Mathf.Sin(beta));
        Gizmos.color = col;
        Gizmos.DrawSphere(GlassToWorld(pos), 0.005f);
        Gizmos.DrawLine(GlassToWorld(pos + bDir * w.bladeSMin),
                        GlassToWorld(pos + bDir * w.bladeSMax));
    }

    void DrawArmAndBlade(WiperConfig w, float theta, Color col)
    {
        float beta = (w.bladeAngle + 90f) * Mathf.Deg2Rad;
        Vector2 armDir  = new Vector2(Mathf.Sin(theta),  Mathf.Cos(theta));
        Vector2 perpDir = new Vector2(Mathf.Cos(theta), -Mathf.Sin(theta));

        Vector2 armTip   = w.pivotPos + armDir  * w.armLength;
        Vector2 bladeCtr = armTip     + perpDir * w.bladeYOffset;

        // Blade direction in glassUV space
        float   ba       = theta - beta;
        Vector2 bladeDir = new Vector2(Mathf.Cos(ba), -Mathf.Sin(ba));

        Vector2 bs = bladeCtr + bladeDir * w.bladeSMin;
        Vector2 be = bladeCtr + bladeDir * w.bladeSMax;

        // Arm
        Gizmos.color = col;
        Gizmos.DrawLine(GlassToWorld(w.pivotPos), GlassToWorld(armTip));

        // Blade center marker
        Gizmos.DrawSphere(GlassToWorld(bladeCtr), 0.005f);

        // Blade
        Gizmos.DrawLine(GlassToWorld(bs), GlassToWorld(be));
    }

    // Blade start/end helpers (for envelope drawing)
    Vector2 BladeStart(WiperConfig w, float theta)
    {
        float beta = (w.bladeAngle + 90f) * Mathf.Deg2Rad;
        Vector2 armDir  = new Vector2(Mathf.Sin(theta),  Mathf.Cos(theta));
        Vector2 perpDir = new Vector2(Mathf.Cos(theta), -Mathf.Sin(theta));
        Vector2 armTip  = w.pivotPos + armDir  * w.armLength;
        Vector2 ctr     = armTip     + perpDir * w.bladeYOffset;
        float   ba      = theta - beta;
        Vector2 bDir    = new Vector2(Mathf.Cos(ba), -Mathf.Sin(ba));
        return ctr + bDir * w.bladeSMin;
    }

    Vector2 BladeEnd(WiperConfig w, float theta)
    {
        float beta = (w.bladeAngle + 90f) * Mathf.Deg2Rad;
        Vector2 armDir  = new Vector2(Mathf.Sin(theta),  Mathf.Cos(theta));
        Vector2 perpDir = new Vector2(Mathf.Cos(theta), -Mathf.Sin(theta));
        Vector2 armTip  = w.pivotPos + armDir  * w.armLength;
        Vector2 ctr     = armTip     + perpDir * w.bladeYOffset;
        float   ba      = theta - beta;
        Vector2 bDir    = new Vector2(Mathf.Cos(ba), -Mathf.Sin(ba));
        return ctr + bDir * w.bladeSMax;
    }

    // -------------------------------------------------------
    //  Mesh-based UV → world mapping
    // -------------------------------------------------------
    Mesh     _cachedMesh;
    Vector2[] _cachedUVs;
    Vector3[] _cachedVerts;
    int[]     _cachedTris;

    void CacheMesh()
    {
        Mesh m = null;
        var mf = GetComponent<MeshFilter>();
        if (mf != null) m = mf.sharedMesh;
        if (m == null)
        {
            var smr = GetComponent<SkinnedMeshRenderer>();
            if (smr != null) m = smr.sharedMesh;
        }
        if (m == null || m == _cachedMesh) return;

        _cachedMesh  = m;
        _cachedUVs   = m.uv;
        _cachedVerts = m.vertices;
        _cachedTris  = m.triangles;
    }

    // glassUV (0-1) → world via barycentric interpolation over the actual mesh.
    // For UVs outside all triangles (e.g. arm tip beyond glass edge), extrapolates
    // from the nearest triangle instead of jumping to an unrelated fallback position.
    Vector3 GlassToWorld(Vector2 uv)
    {
        if (_cachedTris != null && _cachedUVs != null && _cachedUVs.Length > 0)
        {
            float   bestScore = float.MaxValue;
            Vector3 bestLocal = new Vector3(uv.x - 0.5f, uv.y - 0.5f, 0f);

            for (int t = 0; t < _cachedTris.Length; t += 3)
            {
                int i0 = _cachedTris[t], i1 = _cachedTris[t + 1], i2 = _cachedTris[t + 2];
                Vector2 uv0 = _cachedUVs[i0], uv1 = _cachedUVs[i1], uv2 = _cachedUVs[i2];

                Vector2 v0 = uv1 - uv0, v1 = uv2 - uv0, v2 = uv - uv0;
                float d00 = Vector2.Dot(v0, v0), d01 = Vector2.Dot(v0, v1), d11 = Vector2.Dot(v1, v1);
                float d20 = Vector2.Dot(v2, v0), d21 = Vector2.Dot(v2, v1);
                float denom = d00 * d11 - d01 * d01;
                if (Mathf.Abs(denom) < 1e-10f) continue;

                float bv = (d11 * d20 - d01 * d21) / denom;
                float bw = (d00 * d21 - d01 * d20) / denom;
                float bu = 1f - bv - bw;

                // Score = 0 inside triangle; sum of negative bary magnitudes outside.
                float score = Mathf.Max(0f, -bu) + Mathf.Max(0f, -bv) + Mathf.Max(0f, -bw);
                if (score < bestScore)
                {
                    bestScore = score;
                    bestLocal = bu * _cachedVerts[i0] + bv * _cachedVerts[i1] + bw * _cachedVerts[i2];
                    if (bestScore < 1e-6f) break;  // Exact hit — no need to keep searching
                }
            }
            return transform.TransformPoint(bestLocal);
        }

        // Fallback: standard quad (local = UV - 0.5)
        return transform.TransformPoint(new Vector3(uv.x - 0.5f, uv.y - 0.5f, 0f));
    }

    public enum WiperMode { Car = 0, Train = 1 }

    // -------------------------------------------------------
    //  Per-wiper configuration
    // -------------------------------------------------------
    [System.Serializable]
    public class WiperConfig
    {
        public bool    enabled      = false;

        [Header("Mode")]
        public WiperMode wiperMode = WiperMode.Car;

        [Header("Pivot & Arm  (Pivot mode)")]
        public Vector2 pivotPos     = new Vector2(0.5f, 0.05f);
        public float   armLength    = 0.30f;

        [Header("Blade")]
        public float   bladeYOffset = 0.00f;
        public float   bladeAngle   = 0.00f;
        public float   bladeSMin    = -0.20f;
        public float   bladeSMax    =  0.20f;

        [Header("Sweep  (Pivot mode)")]
        public float   armAngleMin  = -40f;
        public float   armAngleMax  =  40f;
        [Tooltip("+1 = starts at angleMin  |  -1 = starts at angleMax")]
        public float   direction    =  1f;

    }
}
