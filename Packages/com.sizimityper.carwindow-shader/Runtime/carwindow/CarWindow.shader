Shader "Custom/CarWindow"
{
    Properties
    {
        // --- Rain beads ---
        _RainAmount    ("Rain Amount",          Range(0,1))   = 0.7
        _DropScale     ("Drop Scale",           Range(0.1,20)) = 1.0
        _RefractionStr ("Refraction Strength",  Range(0,1)) = 0.15
        _ReformRate    ("Drop Reform Rate",     Range(0.05,10)) = 0.3

        // --- Frost ---
        _FrostAmount   ("Frost Amount",         Range(0,1))   = 0.0
        _FrostColor    ("Frost Color",          Color)        = (0.95, 0.97, 1.0, 1.0)

        // --- Glass ---
        _GlassTint     ("Glass Tint",           Color)        = (0.92, 0.96, 1.0, 1.0)
        _Reflectivity  ("Reflectivity",          Range(0,1))   = 0.8

        // --- Rim lighting ---
        _RimStrength   ("Rim Strength",          Range(0, 3))  = 0.8
        _RimColor      ("Rim Color",             Color)        = (0.8, 0.9, 1.0, 1.0)

        // --- Wiper streak ---
        _WiperStreakWidth    ("Wiper Edge Streak Width", Range(0, 0.05)) = 0.005
        _WiperArcStreakWidth ("Wiper Arc Streak Width",  Range(0, 0.05)) = 0.005

        // --- Rendering ---
        [Enum(UnityEngine.Rendering.CullMode)] _CullMode ("Cull Mode", Float) = 0
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" }

        GrabPass { }

        Pass
        {
            Name "CarWindowMain"
            Tags { "LightMode" = "ForwardBase" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull [_CullMode]

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.5
            #pragma multi_compile _ UNITY_SPECCUBE_BLENDING
            #pragma multi_compile _ UNITY_SPECCUBE_BOX_PROJECTION

            #include "UnityCG.cginc"

            // ---------- samplers ----------
            sampler2D _GrabTexture;
            float4    _GrabTexture_TexelSize;

            // ---------- scalar properties ----------
            float  _RainAmount;
            float  _DropScale;
            float  _RefractionStr;
            float  _ReformRate;
            float  _FrostAmount;
            float4 _FrostColor;
            float  _WiperStreakWidth;
            float  _WiperArcStreakWidth;
            float  _RimStrength;
            float4 _RimColor;
            float  _WiperPeriod;
            float  _WiperInterval;
            float  _WiperTimeInCycle;  // set each frame by CarWindowWiperSync
            float4 _GlassTint;
            float  _Reflectivity;

            // ---------- wiper arrays ----------
            // Set each frame by CarWindowGizmo via Material.SetVectorArray.
            // _WiperPivotArm[i] = (pivotX, pivotY, armLength, bladeYOffset)
            // _WiperBlade[i]    = (bladeAngle_deg, bladeSMin, bladeSMax, 0)
            // _WiperAngles[i]   = (armAngleMin_deg, armAngleMax_deg, enabled, direction)
            //   direction: +1 = starts at angleMin, -1 = starts at angleMax
            uniform float4 _WiperPivotArm[4];
            uniform float4 _WiperBlade[4];
            uniform float4 _WiperAngles[4];

            // =========================================================
            //  Structs
            // =========================================================
            struct appdata
            {
                float4 vertex   : POSITION;
                float3 normal   : NORMAL;
                float2 texcoord : TEXCOORD0;
            };

            struct v2f
            {
                float4 pos      : SV_POSITION;
                float4 grabPos  : TEXCOORD0;
                float3 worldPos : TEXCOORD1;
                float3 worldNorm: TEXCOORD2;
                float2 glassUV  : TEXCOORD3;
            };

            // =========================================================
            //  Box projection helper
            // =========================================================
            float3 BoxProjectDir(float3 r, float3 wPos,
                                 float4 pp, float4 bMin, float4 bMax)
            {
                #if UNITY_SPECCUBE_BOX_PROJECTION
                if (pp.w > 0)
                {
                    float3 rbmax = (bMax.xyz - wPos) / r;
                    float3 rbmin = (bMin.xyz - wPos) / r;
                    float3 rbmm  = (r > 0) ? rbmax : rbmin;
                    float  fa    = min(min(rbmm.x, rbmm.y), rbmm.z);
                    r = wPos + r * fa - pp.xyz;
                }
                #endif
                return r;
            }

            // =========================================================
            //  Hash helpers
            // =========================================================
            float  h1(float2 p) { return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
            float2 h2(float2 p) { return float2(h1(p), h1(p + float2(31.41, 27.18))); }

            // =========================================================
            //  Wiper test
            //  Returns float2(inZone, accumFactor)
            //    inZone:      1 if pixel is within this arm's sweep envelope
            //    accumFactor: 0 = just wiped,  1 = fully re-accumulated
            //
            //  Math derivation (arm local frame: X=arm dir, Y=perp, Z=out):
            //    Blade center at arm angle θ:
            //      B(θ) = pivot + L*(sinθ,cosθ) + d*(cosθ,−sinθ)
            //    Blade direction: (cos(θ−β), −sin(θ−β))  where β = bladeAngle
            //    Perpendicular condition Q on blade → after trig simplification:
            //      R·sin(θ−β + atan2(Δy,Δx)) = K,  K = L·cosβ − d·sinβ
            //    Two crossing angles:
            //      θ = β − atan2(Δy,Δx) ± arcsin(K/R)
            // =========================================================
            float2 WiperTest(float2 uv, int idx)
            {
                float  beta   = _WiperBlade[idx].x * (3.14159265 / 180.0);
                float  sMin   = _WiperBlade[idx].y;
                float  sMax   = _WiperBlade[idx].z;
                float  mode   = _WiperBlade[idx].w;
                float  dir    = _WiperAngles[idx].w;

                float period      = max(_WiperPeriod, 0.001);
                float halfP       = period * 0.5;
                float cycleDur    = period + max(_WiperInterval, 0.0);
                float timeInCycle = _WiperTimeInCycle;

                // ---- Pivot-angle mode (shared params) ----
                float2 pivot  = _WiperPivotArm[idx].xy;
                float  L      = _WiperPivotArm[idx].z;
                float  bladeY = _WiperPivotArm[idx].w;
                float  tMin   = _WiperAngles[idx].x * (3.14159265 / 180.0);
                float  tMax   = _WiperAngles[idx].y * (3.14159265 / 180.0);

                float tRange = tMax - tMin;
                if (abs(tRange) < 0.001) return float2(0, 1);
                if (tRange < 0.0)
                {
                    float tmp = tMin; tMin = tMax; tMax = tmp;
                    tRange = -tRange;
                    dir    = -dir;
                }

                // ---- Parallel crank mode (mode 1): fan sweep + fixed blade in UV space ----
                if (mode > 0.5)
                {
                    float2 bladeDir  = float2(cos(beta), -sin(beta));  // fixed in UV space
                    float2 bladePerp = float2(sin(beta),  cos(beta));

                    float M   = sqrt(L * L + bladeY * bladeY);
                    if (M < 1e-5) return float2(0, 1);
                    float phi = atan2(bladeY, L);

                    // W = dot(uv-pivot, bladePerp) = M*cos(theta - beta + phi)  at crossing theta
                    float W = dot(uv - pivot, bladePerp);
                    if (abs(W) > M) return float2(0, 1);

                    float arcW = acos(clamp(W / M, -0.9999, 0.9999));

                    float bestSince1 = cycleDur;
                    float inZone1    = 0.0;

                    [unroll]
                    for (int s = 0; s < 2; s++)
                    {
                        // theta - beta + phi = ±arcW  →  theta = (beta - phi) ± arcW
                        float theta = (beta - phi) + (s == 0 ? arcW : -arcW);
                        theta -= 6.28318530 * floor((theta - tMin) / 6.28318530);
                        if (theta > tMax + 1e-4) continue;

                        float sinT = sin(theta), cosT = cos(theta);
                        float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                        float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);
                        float  proj     = dot(uv - bladeCtr, bladeDir);  // fixed direction!
                        if (proj < sMin || proj > sMax) continue;

                        inZone1 = 1.0;

                        float norm = (theta - tMin) / tRange;
                        if (dir < 0.0) norm = 1.0 - norm;

                        float t_cross1 = norm * halfP;
                        float t_cross2 = period - norm * halfP;

                        float since1 = timeInCycle - t_cross1;
                        since1 -= cycleDur * floor(since1 / cycleDur);
                        float since2 = timeInCycle - t_cross2;
                        since2 -= cycleDur * floor(since2 / cycleDur);

                        bestSince1 = min(bestSince1, min(since1, since2));
                    }

                    return float2(inZone1, saturate(bestSince1 / (period * _ReformRate)));
                }

                // ---- Pivot-angle mode (mode 0) ----
                float2 delta = uv - pivot;
                float  R     = length(delta);
                if (R < 1e-5) return float2(0, 1);

                float K = L * cos(beta) - bladeY * sin(beta);
                if (abs(K / R) > 1.0) return float2(0, 1);

                float arcV = asin(clamp(K / R, -0.9999, 0.9999));
                float base = beta - atan2(delta.y, delta.x);

                float bestSince = cycleDur;
                float inZone    = 0.0;

                [unroll]
                for (int s = 0; s < 2; s++)
                {
                    float theta = base + (s == 0 ? arcV : (3.14159265 - arcV));
                    theta -= 6.28318530 * floor((theta - tMin) / 6.28318530);
                    if (theta > tMax + 1e-4) continue;

                    float sinT = sin(theta), cosT = cos(theta);
                    float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                    float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);
                    float2 bladeDir = float2(cos(theta - beta), -sin(theta - beta));
                    float  proj     = dot(uv - bladeCtr, bladeDir);
                    if (proj < sMin || proj > sMax) continue;

                    inZone = 1.0;

                    float norm = (theta - tMin) / tRange;
                    if (dir < 0.0) norm = 1.0 - norm;

                    float t_cross1 = norm * halfP;
                    float t_cross2 = period - norm * halfP;

                    float since1 = timeInCycle - t_cross1;
                    since1 -= cycleDur * floor(since1 / cycleDur);
                    float since2 = timeInCycle - t_cross2;
                    since2 -= cycleDur * floor(since2 / cycleDur);

                    bestSince = min(bestSince, min(since1, since2));
                }

                return float2(inZone, saturate(bestSince / (period * _ReformRate)));
            }

            // =========================================================
            //  Wiper angular edge streak
            //  Water film that accumulates at armAngleMin / armAngleMax edges.
            //  Returns a refraction normal contribution.
            // =========================================================
            float2 WiperEdgeStreak(float2 uv, int idx)
            {
                if (_WiperAngles[idx].z < 0.5) return float2(0, 0);

                float  beta  = _WiperBlade[idx].x * (3.14159265 / 180.0);
                float  sMin  = _WiperBlade[idx].y;
                float  sMax  = _WiperBlade[idx].z;
                float  mode  = _WiperBlade[idx].w;
                float  sw    = max(_WiperStreakWidth, 1e-5);
                float2 streakNorm = float2(0, 0);

                // ---- Parallel crank mode: angle edges at tMin / tMax, fixed blade direction ----
                if (mode > 0.5)
                {
                    float2 pivot  = _WiperPivotArm[idx].xy;
                    float  L      = _WiperPivotArm[idx].z;
                    float  bladeY = _WiperPivotArm[idx].w;
                    float  tMin   = _WiperAngles[idx].x * (3.14159265 / 180.0);
                    float  tMax   = _WiperAngles[idx].y * (3.14159265 / 180.0);
                    if (tMax < tMin) { float tmp = tMin; tMin = tMax; tMax = tmp; }

                    float2 bladeDir  = float2(cos(beta), -sin(beta));  // fixed in UV space
                    float2 bladePerp = float2(sin(beta),  cos(beta));

                    [unroll]
                    for (int e = 0; e < 2; e++)
                    {
                        float theta = (e == 0) ? tMin : tMax;
                        float sinT = sin(theta), cosT = cos(theta);
                        float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                        float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);

                        float proj = dot(uv - bladeCtr, bladeDir);
                        float perp = dot(uv - bladeCtr, bladePerp);
                        if (proj < sMin || proj > sMax) continue;

                        float s = saturate(1.0 - abs(perp) / sw);
                        s *= s;
                        streakNorm += (perp >= 0.0 ? 1.0 : -1.0) * bladePerp * s;
                    }
                    return streakNorm * _RainAmount;
                }

                // ---- Pivot mode ----
                float2 pivot  = _WiperPivotArm[idx].xy;
                float  L      = _WiperPivotArm[idx].z;
                float  bladeY = _WiperPivotArm[idx].w;
                float  tMin   = _WiperAngles[idx].x * (3.14159265 / 180.0);
                float  tMax   = _WiperAngles[idx].y * (3.14159265 / 180.0);
                if (tMax < tMin) { float tmp = tMin; tMin = tMax; tMax = tmp; }

                [unroll]
                for (int e = 0; e < 2; e++)
                {
                    float theta = (e == 0) ? tMin : tMax;
                    float sinT = sin(theta), cosT = cos(theta);
                    float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                    float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);
                    float  ba       = theta - beta;
                    float2 bladeDir  = float2( cos(ba), -sin(ba));
                    float2 bladePerp = float2( sin(ba),  cos(ba));

                    float proj = dot(uv - bladeCtr, bladeDir);
                    float perp = dot(uv - bladeCtr, bladePerp);
                    if (proj < sMin || proj > sMax) continue;

                    float s = saturate(1.0 - abs(perp) / sw);
                    s *= s;
                    streakNorm += (perp >= 0.0 ? 1.0 : -1.0) * bladePerp * s;
                }

                return streakNorm * _RainAmount;
            }

            // =========================================================
            //  Wiper arc streak
            //  Water film at the outer (sMax) and inner (sMin) arc boundaries.
            //  Uses the same crossing-theta math as WiperTest.
            // =========================================================
            float2 WiperArcStreak(float2 uv, int idx)
            {
                if (_WiperAngles[idx].z < 0.5) return float2(0, 0);

                float  beta  = _WiperBlade[idx].x * (3.14159265 / 180.0);
                float  sMin  = _WiperBlade[idx].y;
                float  sMax  = _WiperBlade[idx].z;
                float  mode  = _WiperBlade[idx].w;
                float  sw    = max(_WiperArcStreakWidth, 1e-5);
                float2 streakNorm = float2(0, 0);

                // ---- Parallel crank mode: fan sweep + fixed blade, same arc crossing math ----
                if (mode > 0.5)
                {
                    float2 pivot  = _WiperPivotArm[idx].xy;
                    float  L      = _WiperPivotArm[idx].z;
                    float  bladeY = _WiperPivotArm[idx].w;
                    float  tMin   = _WiperAngles[idx].x * (3.14159265 / 180.0);
                    float  tMax   = _WiperAngles[idx].y * (3.14159265 / 180.0);

                    float tRange2 = tMax - tMin;
                    if (abs(tRange2) < 0.001) return float2(0, 0);
                    if (tRange2 < 0.0) { float tmp = tMin; tMin = tMax; tMax = tmp; }

                    float2 bladeDir  = float2(cos(beta), -sin(beta));  // fixed in UV space
                    float2 bladePerp = float2(sin(beta),  cos(beta));

                    float M2  = sqrt(L * L + bladeY * bladeY);
                    if (M2 < 1e-5) return float2(0, 0);
                    float phi2 = atan2(bladeY, L);

                    float W2 = dot(uv - pivot, bladePerp);
                    if (abs(W2) > M2) return float2(0, 0);

                    float arcW2 = acos(clamp(W2 / M2, -0.9999, 0.9999));

                    [unroll]
                    for (int s = 0; s < 2; s++)
                    {
                        float theta = (beta - phi2) + (s == 0 ? arcW2 : -arcW2);
                        theta -= 6.28318530 * floor((theta - tMin) / 6.28318530);
                        if (theta > tMax + 1e-4) continue;

                        float sinT = sin(theta), cosT = cos(theta);
                        float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                        float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);
                        float  proj     = dot(uv - bladeCtr, bladeDir);

                        float sOuter = saturate(1.0 - abs(proj - sMax) / sw); sOuter *= sOuter;
                        streakNorm += bladeDir * sOuter;

                        float sInner = saturate(1.0 - abs(proj - sMin) / sw); sInner *= sInner;
                        streakNorm -= bladeDir * sInner;
                    }
                    return streakNorm * _RainAmount;
                }

                // ---- Pivot mode ----
                float2 pivot  = _WiperPivotArm[idx].xy;
                float  L      = _WiperPivotArm[idx].z;
                float  bladeY = _WiperPivotArm[idx].w;
                float  tMin   = _WiperAngles[idx].x * (3.14159265 / 180.0);
                float  tMax   = _WiperAngles[idx].y * (3.14159265 / 180.0);

                float tRange = tMax - tMin;
                if (abs(tRange) < 0.001) return float2(0, 0);
                if (tRange < 0.0) { float tmp = tMin; tMin = tMax; tMax = tmp; tRange = -tRange; }

                float2 delta = uv - pivot;
                float  R     = length(delta);
                if (R < 1e-5) return float2(0, 0);

                float K = L * cos(beta) - bladeY * sin(beta);
                if (abs(K / R) > 1.0) return float2(0, 0);

                float arcV = asin(clamp(K / R, -0.9999, 0.9999));
                float base = beta - atan2(delta.y, delta.x);
                float2 radial = delta / R;

                [unroll]
                for (int s = 0; s < 2; s++)
                {
                    float theta = base + (s == 0 ? arcV : (3.14159265 - arcV));
                    theta -= 6.28318530 * floor((theta - tMin) / 6.28318530);
                    if (theta > tMax + 1e-4) continue;

                    float sinT = sin(theta), cosT = cos(theta);
                    float2 armTip   = pivot   + L      * float2(sinT,  cosT);
                    float2 bladeCtr = armTip  + bladeY * float2(cosT, -sinT);
                    float2 bladeDir = float2(cos(theta - beta), -sin(theta - beta));
                    float  proj     = dot(uv - bladeCtr, bladeDir);

                    float sOuter = saturate(1.0 - abs(proj - sMax) / sw); sOuter *= sOuter;
                    streakNorm += radial * sOuter;

                    float sInner = saturate(1.0 - abs(proj - sMin) / sw); sInner *= sInner;
                    streakNorm -= radial * sInner;
                }

                return streakNorm * _RainAmount;
            }

            // =========================================================
            //  Bead drop normal
            //  Returns xy screen-space refraction normal.
            //  dynamic=0: static beads (always visible)
            //  dynamic=1: beads appear suddenly when accumFactor > birthThreshold
            // =========================================================
            float2 BeadNormal(float2 uv, float dynamic, float accumFactor)
            {
                float2 norm = float2(0, 0);

                // Three scales: large / medium / small drops
                [unroll]
                for (int sc = 0; sc < 3; sc++)
                {
                    float baseScale = (sc == 0) ? 5.0 : (sc == 1) ? 8.0 : 12.0;
                    float scale     = baseScale * _DropScale;
                    float maxR      = (sc == 0) ? 0.04 : (sc == 1) ? 0.04 : 0.03;

                    float2 scaledUV = uv * scale;
                    float2 cellID   = floor(scaledUV);
                    float2 cellUV   = frac(scaledUV);

                    // Medium/small drops: skip if inside a large drop
                    if (sc >= 1)
                    {
                        float2 lUV     = uv * (5.0 * _DropScale);
                        float2 lCellID = floor(lUV);
                        float2 lCellUV = frac(lUV);
                        float2 lCenter = 0.1 + h2(lCellID) * 0.8;
                        float  lR      = 0.08 + h1(lCellID + float2(0.0, 0.7)) * 0.04;
                        float  lFit    = min(min(lCenter.x, 1.0 - lCenter.x), min(lCenter.y, 1.0 - lCenter.y));
                        lR = min(lR, lFit);
                        if (length(lCellUV - lCenter) < lR) continue;
                    }

                    // Small drops: also skip if inside a medium drop
                    if (sc == 2)
                    {
                        float2 mUV     = uv * (8.0 * _DropScale);
                        float2 mCellID = floor(mUV);
                        float2 mCellUV = frac(mUV);
                        float2 mCenter = 0.1 + h2(mCellID + float2(7.3, 3.1)) * 0.8;
                        float  mR      = 0.08 + h1(mCellID + float2(1.9, 0.7)) * 0.04;
                        float  mFit    = min(min(mCenter.x, 1.0 - mCenter.x), min(mCenter.y, 1.0 - mCenter.y));
                        mR = min(mR, mFit);
                        if (length(mCellUV - mCenter) < mR) continue;
                    }

                    float2 rnd    = h2(cellID + float2(sc * 7.3, sc * 3.1));
                    float2 center = 0.1 + rnd * 0.8;
                    float  r      = 0.08 + h1(cellID + float2(sc * 1.9, 0.7)) * maxR;

                    // Clamp radius so the drop never crosses into adjacent cells
                    float maxFit = min(min(center.x, 1.0 - center.x), min(center.y, 1.0 - center.y));
                    r = min(r, maxFit);

                    // Dynamic: appear only once accumFactor exceeds per-cell threshold
                    float birth    = h1(cellID + float2(sc * 2.7, 5.1));
                    float appeared = (dynamic > 0.5) ? step(birth, accumFactor) : 1.0;

                    float2 d    = cellUV - center;
                    float  dist = length(d);
                    if (dist >= r) continue;

                    // Outward spherical normal; magnitude ∝ dist/r (0 at centre, 1 at edge)
                    float2 n = d / (r + 1e-5);   // magnitude = dist/r
                    norm += n * appeared * _RainAmount;
                }

                return norm;
            }

            // =========================================================
            //  Vertex shader
            // =========================================================
            v2f vert(appdata v)
            {
                v2f o;
                o.pos      = UnityObjectToClipPos(v.vertex);
                o.grabPos  = ComputeGrabScreenPos(o.pos);
                o.worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.worldNorm= UnityObjectToWorldNormal(v.normal);
                // Car shader: glassUV = raw texcoord, Y-up = top of windshield
                o.glassUV  = v.texcoord.xy;
                return o;
            }

            // =========================================================
            //  Fragment shader
            // =========================================================
            float4 frag(v2f i, float facing : VFACE) : SV_Target
            {
                float2 glassUV = i.glassUV;

                // --- Wiper zone test: call once per wiper, store as scalars (no dynamic indexing) ---
                float wz0 = 0, wa0 = 1, wz1 = 0, wa1 = 1, wz2 = 0, wa2 = 1, wz3 = 0, wa3 = 1;
                if (_WiperAngles[0].z >= 0.5) { float2 r = WiperTest(glassUV, 0); wz0 = r.x; wa0 = r.y; }
                if (_WiperAngles[1].z >= 0.5) { float2 r = WiperTest(glassUV, 1); wz1 = r.x; wa1 = r.y; }
                if (_WiperAngles[2].z >= 0.5) { float2 r = WiperTest(glassUV, 2); wz2 = r.x; wa2 = r.y; }
                if (_WiperAngles[3].z >= 0.5) { float2 r = WiperTest(glassUV, 3); wz3 = r.x; wa3 = r.y; }

                float inZone      = max(max(wz0, wz1), max(wz2, wz3));
                float accumFactor = 1.0;
                if (wz0 > 0.5) accumFactor = min(accumFactor, wa0);
                if (wz1 > 0.5) accumFactor = min(accumFactor, wa1);
                if (wz2 > 0.5) accumFactor = min(accumFactor, wa2);
                if (wz3 > 0.5) accumFactor = min(accumFactor, wa3);

                // --- Bead normals ---
                float2 dropNorm = BeadNormal(glassUV, inZone, accumFactor);

                // --- Wiper edge + arc streaks ---
                // Each wiper's streak is masked out wherever any OTHER wiper's zone is active.
                // otherZone for wiper N = max of wz* for all wipers except N.
                float2 streakNorm = float2(0, 0);
                streakNorm += (WiperEdgeStreak(glassUV, 0) + WiperArcStreak(glassUV, 0)) * (1.0 - max(max(wz1, wz2), wz3));
                streakNorm += (WiperEdgeStreak(glassUV, 1) + WiperArcStreak(glassUV, 1)) * (1.0 - max(max(wz0, wz2), wz3));
                streakNorm += (WiperEdgeStreak(glassUV, 2) + WiperArcStreak(glassUV, 2)) * (1.0 - max(max(wz0, wz1), wz3));
                streakNorm += (WiperEdgeStreak(glassUV, 3) + WiperArcStreak(glassUV, 3)) * (1.0 - max(max(wz0, wz1), wz2));
                dropNorm += streakNorm * 0.5;

                // --- GrabPass refraction + frost blur ---
                float2 grabUV = i.grabPos.xy / i.grabPos.w;
                grabUV += dropNorm * _RefractionStr;

                // Frost is cleared by wiper (follows accumFactor) and absent under drops
                float wiperClear = lerp(1.0, accumFactor, inZone);
                float dropClear  = 1.0 - saturate(length(dropNorm) * 8.0);
                float effectiveFrost = _FrostAmount * wiperClear * dropClear;

                float3 bgClear = tex2D(_GrabTexture, grabUV).rgb;
                float3 bgBlur  = bgClear;
                [branch]
                if (effectiveFrost > 0.001)
                {
                    float2 ts = _GrabTexture_TexelSize.xy * (effectiveFrost * 40.0);
                    bgBlur  = tex2D(_GrabTexture, grabUV + float2( ts.x,    0)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2(-ts.x,    0)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2(    0, ts.y)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2(    0,-ts.y)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2( ts.x, ts.y)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2(-ts.x, ts.y)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2( ts.x,-ts.y)).rgb;
                    bgBlur += tex2D(_GrabTexture, grabUV + float2(-ts.x,-ts.y)).rgb;
                    bgBlur = (bgBlur + bgClear) / 9.0;
                }
                float3 bgFrost = lerp(bgBlur, _FrostColor.rgb, effectiveFrost * 0.4);
                float3 bg = lerp(bgClear, bgFrost, effectiveFrost) * _GlassTint.rgb;

                // --- Fresnel + Reflection Probe ---
                float3 N = normalize(i.worldNorm) * sign(facing);
                float3 V = normalize(UnityWorldSpaceViewDir(i.worldPos));
                float  fresnel = pow(1.0 - saturate(dot(N, V)),
                                     lerp(8.0, 1.0, _Reflectivity));

                float3 R   = reflect(-V, N);
                float  lod = (1.0 - _Reflectivity) * 6.0;
                float3 R0  = BoxProjectDir(R, i.worldPos,
                    unity_SpecCube0_ProbePosition,
                    unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
                float4 env0 = UNITY_SAMPLE_TEXCUBE_LOD(unity_SpecCube0, R0, lod);
                float3 refl = DecodeHDR(env0, unity_SpecCube0_HDR);
                #if UNITY_SPECCUBE_BLENDING
                    float blendW = unity_SpecCube0_BoxMin.w;
                    UNITY_BRANCH
                    if (blendW < 0.99999)
                    {
                        float3 R1 = BoxProjectDir(R, i.worldPos,
                            unity_SpecCube1_ProbePosition,
                            unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);
                        float4 env1 = UNITY_SAMPLE_TEXCUBE_SAMPLER_LOD(
                            unity_SpecCube1, unity_SpecCube0, R1, lod);
                        refl = lerp(DecodeHDR(env1, unity_SpecCube1_HDR), refl, blendW);
                    }
                #endif
                refl *= _Reflectivity;

                // --- Drop specular ---
                float3 dropN  = normalize(float3(dropNorm * 6.0, 1.0));
                float3 lDir   = normalize(float3(0.3, 1.0, 0.5));
                float3 hVec   = normalize(V + lDir);
                float  spec   = pow(max(0.0, dot(dropN, hVec)), 32.0)
                              * length(dropNorm) * _Reflectivity;
                float3 streakN = normalize(float3(streakNorm * 6.0, 1.0));
                float  streakSpec = pow(max(0.0, dot(streakN, hVec)), 16.0)
                                  * length(streakNorm) * _Reflectivity;

                // --- Rim lighting ---
                // dropN.z / streakN.z = 1 at surface center, < 1 at edges
                float dropRim   = pow(saturate(1.0 - dropN.z),   2.0) * length(dropNorm);
                float streakRim = pow(saturate(1.0 - streakN.z), 2.0) * length(streakNorm);
                float3 rimCol   = (dropRim + streakRim) * _RimStrength * _RimColor.rgb;

                // --- Composite ---
                float3 col   = bg + refl * fresnel + spec + streakSpec + rimCol;
                float  alpha = lerp(0.05, 0.8, fresnel) + length(dropNorm) * 0.15;
                return float4(col, saturate(alpha));
            }
            ENDCG
        }
    }

    FallBack "Transparent/Diffuse"
}
