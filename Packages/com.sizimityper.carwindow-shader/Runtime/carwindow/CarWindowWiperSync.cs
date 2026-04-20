using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

/// <summary>
/// CarWindow.shaderのVRChatランタイムワイパーメッシュ同期。
///
/// WiperSyncはタイミングのマスター: 毎フレームlocalTを計算し、
/// メッシュピボットを動かし、_WiperTimeInCycleをマテリアルに書き込む。
/// シェーダーは_WiperTimeInCycleを直接使用し、完全な同期を保証する。
/// </summary>
public class CarWindowWiperSync : UdonSharpBehaviour
{
    [Header("Material")]
    public Material carWindowMaterial;

    // -------------------------------------------------------
    //  CarWindowGizmoによるベイク済み — 手動で編集しないこと
    // -------------------------------------------------------
    [HideInInspector] public bool      bakedReady    = false;
    [HideInInspector] public float     bakedPeriod   = 2.0f;
    [HideInInspector] public float     bakedInterval = 0.0f;
    [HideInInspector] public Vector4[] bakedPivotArm = new Vector4[4];
    [HideInInspector] public Vector4[] bakedBlade    = new Vector4[4];
    [HideInInspector] public Vector4[] bakedAngles   = new Vector4[4];

    // -------------------------------------------------------
    //  メッシュ専用設定 — 手動で設定
    // -------------------------------------------------------
    [Header("Wiper 0 — mesh only")]
    public Transform w0Pivot;
    [Tooltip("ピボットトランスフォームがidentity回転のときにアームがglassUV空間で指す角度（度）。0 = 真上（+Y）。モデリングしたメッシュの向きに合わせること。")]
    public float     w0MeshRestAngle = 0f;

    [Header("Wiper 1 — mesh only")]
    public Transform w1Pivot;
    [Tooltip("ピボットトランスフォームがidentity回転のときにアームがglassUV空間で指す角度（度）。")]
    public float     w1MeshRestAngle = 0f;

    [Header("Wiper 2 — mesh only")]
    public Transform w2Pivot;
    [Tooltip("ピボットトランスフォームがidentity回転のときにアームがglassUV空間で指す角度（度）。")]
    public float     w2MeshRestAngle = 0f;

    [Header("Wiper 3 — mesh only")]
    public Transform w3Pivot;
    [Tooltip("ピボットトランスフォームがidentity回転のときにアームがglassUV空間で指す角度（度）。")]
    public float     w3MeshRestAngle = 0f;

    private Material mat;

    void Start()
    {
        // 複製したオブジェクト間でStateが共有されないようインスタンスごとのマテリアルを作成
        Renderer rend = GetComponent<Renderer>();
        mat = (rend != null) ? rend.material : carWindowMaterial;
    }

    void LateUpdate()
    {
        if (mat == null) return;

        // ベイク済みジオメトリ + 角度をマテリアルに転送（CarWindowGizmoによるベイク済みの場合のみ）
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

        // 同じlocalTでシェーダーを駆動 — 完全な同期を保証
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
        // wiperAngle: (最小角度, 最大角度, 有効フラグ, 方向)
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
