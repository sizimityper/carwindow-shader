using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// VRChat runtime wiper mesh sync for CarWindow.shader.
///
/// WiperSync is the master of timing: it computes localT each frame,
/// drives the mesh pivot, and writes _WiperTimeInCycle to the material.
/// The shader uses _WiperTimeInCycle directly, guaranteeing perfect sync.
/// </summary>
public class CarWindowWiperSync : UdonSharpBehaviour
{
    [Header("Material")]
    public Material carWindowMaterial;

    // -------------------------------------------------------
    //  Baked by CarWindowGizmo — do not edit manually
    // -------------------------------------------------------
    [HideInInspector] public bool      bakedReady    = false;
    [HideInInspector] public float     bakedPeriod   = 2.0f;
    [HideInInspector] public float     bakedInterval = 0.0f;
    [HideInInspector] public Vector4[] bakedPivotArm = new Vector4[4];
    [HideInInspector] public Vector4[] bakedBlade    = new Vector4[4];
    [HideInInspector] public Vector4[] bakedAngles   = new Vector4[4];

    // -------------------------------------------------------
    //  Mesh-only settings — set manually
    // -------------------------------------------------------
    [Header("Wiper 0 — mesh only")]
    public Transform w0Pivot;
    [Tooltip("Angle (deg) the arm points in glassUV space when pivot transform is at identity rotation. 0 = straight up (+Y). Match this to your modeled mesh orientation.")]
    public float     w0MeshRestAngle = 0f;

    [Header("Wiper 1 — mesh only")]
    public Transform w1Pivot;
    [Tooltip("Angle (deg) the arm points in glassUV space when pivot transform is at identity rotation.")]
    public float     w1MeshRestAngle = 0f;

    [Header("Wiper 2 — mesh only")]
    public Transform w2Pivot;
    [Tooltip("Angle (deg) the arm points in glassUV space when pivot transform is at identity rotation.")]
    public float     w2MeshRestAngle = 0f;

    [Header("Wiper 3 — mesh only")]
    public Transform w3Pivot;
    [Tooltip("Angle (deg) the arm points in glassUV space when pivot transform is at identity rotation.")]
    public float     w3MeshRestAngle = 0f;

    private Material mat;

    void Start()
    {
        // Create a per-instance material so duplicated objects don't share state
        Renderer rend = GetComponent<Renderer>();
        mat = (rend != null) ? rend.material : carWindowMaterial;
    }

    void LateUpdate()
    {
        if (mat == null) return;

        // Push baked geometry + angles to material (only if baked by CarWindowGizmo)
        if (bakedReady)
        {
            mat.SetVectorArray("_WiperPivotArm", bakedPivotArm);
            mat.SetVectorArray("_WiperBlade",    bakedBlade);
            mat.SetVectorArray("_WiperAngles",   bakedAngles);
        }

        float period   = Mathf.Max(bakedPeriod,   0.001f);
        float interval = Mathf.Max(bakedInterval, 0.0f);
        mat.SetFloat("_WiperPeriod",   period);
        mat.SetFloat("_WiperInterval", interval);
        float cycleDur = period + interval;
        float halfP    = period * 0.5f;
        float localT   = Mathf.Repeat(Time.time, cycleDur);

        // Drive shader with the same localT — perfect sync guaranteed
        mat.SetFloat("_WiperTimeInCycle", localT);

        float t01 = 0f;
        if (localT < period)
            t01 = (localT < halfP) ? (localT / halfP) : ((period - localT) / halfP);

        ApplyWiper(w0Pivot, w0MeshRestAngle, bakedAngles[0], t01);
        ApplyWiper(w1Pivot, w1MeshRestAngle, bakedAngles[1], t01);
        ApplyWiper(w2Pivot, w2MeshRestAngle, bakedAngles[2], t01);
        ApplyWiper(w3Pivot, w3MeshRestAngle, bakedAngles[3], t01);
    }

    void ApplyWiper(Transform pivot, float meshRestAngle, Vector4 wiperAngle, float t01)
    {
        // wiperAngle: (angleMin, angleMax, enabled, direction)
        if (pivot == null || wiperAngle.z < 0.5f) return;

        float angleMin = wiperAngle.x;
        float angleMax = wiperAngle.y;
        float dir      = wiperAngle.w;

        float shaderAngle = (dir >= 0f)
            ? Mathf.Lerp(angleMin, angleMax, t01)
            : Mathf.Lerp(angleMax, angleMin, t01);

        float   theta      = shaderAngle  * (3.14159265f / 180.0f);
        float   restTheta  = meshRestAngle * (3.14159265f / 180.0f);
        Vector3 targetDir  = new Vector3(Mathf.Sin(theta),     Mathf.Cos(theta),     0f);
        Vector3 armRestDir = new Vector3(Mathf.Sin(restTheta), Mathf.Cos(restTheta), 0f);

        pivot.localRotation = Quaternion.FromToRotation(armRestDir, targetDir);
    }
}
