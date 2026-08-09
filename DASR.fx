// =============================================================================
// DASR v2.5o (Hybrid Grid-Brick Divergence + Anisotropic Surgical Low-Pass)
// Author: Baudelaire (Aston89) / Github: https://github.com/aston89/
// =============================================================================

#include "ReShade.fxh"

#define BUFFER_RCP_SIZE float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT)

// =============================================================================
// BUFFERS
// =============================================================================
texture2D RiskMapBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D RiskMapSampler { Texture = RiskMapBuffer; AddressU = Clamp; AddressV = Clamp; };

texture2D HistoryBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D HistorySampler { Texture = HistoryBuffer; AddressU = Clamp; AddressV = Clamp; };

// Previous-frame history. Used to avoid read/write on the same texture.
texture2D HistoryPrevBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D HistoryPrevSampler { Texture = HistoryPrevBuffer; AddressU = Clamp; AddressV = Clamp; };

// SPATIAL OUTPUT BUFFER Pass 2 -> Pass 2B bridge
texture2D SpatialBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D SpatialSampler { Texture = SpatialBuffer; AddressU = Clamp; AddressV = Clamp; };

// PHASE-STABILIZED SPATIAL BUFFER Pass 2B -> History/Final bridge
texture2D PhaseSpatialBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D PhaseSpatialSampler { Texture = PhaseSpatialBuffer; AddressU = Clamp; AddressV = Clamp; };

// Previous raw spatial frames for A/B/A phase-aware moire detection.
// Important: these buffers store the pre-phase SpatialBuffer, not the EMA history.
texture2D SpatialPrevBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D SpatialPrevSampler { Texture = SpatialPrevBuffer; AddressU = Clamp; AddressV = Clamp; };

texture2D SpatialPrev2Buffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D SpatialPrev2Sampler { Texture = SpatialPrev2Buffer; AddressU = Clamp; AddressV = Clamp; };

// =============================================================================
// PARAMS
// =============================================================================
// ---- Temporal motion heuristic ----
uniform bool UseMotionHeuristic < ui_label = "Temporal Motion Heuristic"; ui_tooltip = "Use a 1-pixel history offset along the local gradient to compensate for small camera motion."; > = true;
uniform int DebugMode < ui_type = "slider"; ui_min = 0; ui_max = 11; ui_step = 1; ui_label = "Debug Mode"; ui_tooltip = "0=Final | 1=Depth | 2=DepthWeight | 3=GridBrickDiv | 4=Periodicity | 5=TemporalRisk | 6=FinalRiskMap | 7=BlurDirection | 8=AdaptiveTaps | 9=MotionOffset | 10=PhaseMoireMask | 11=PhaseOutlierMask"; > = 0;
uniform int FrameCount < source = "framecount"; >;

// ---- Core instability analysis ----
uniform float GridSensitivity < ui_type = "slider"; ui_min = 1.0; ui_max = 50.0; ui_step = 0.5; ui_label = "Grid-Brick Sensitivity"; ui_tooltip = "How strongly sampling-phase divergence should contribute to the aliasing risk."; > = 5.0;
uniform float TemporalSensitivity < ui_type = "slider"; ui_min = 1.0; ui_max = 30.0; ui_step = 0.5; ui_label = "Temporal Sensitivity"; ui_tooltip = "How strongly frame-to-frame differences should contribute to temporal shimmer risk."; > = 8.0;
uniform float MinimumAliasConfidence < ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01; ui_label = "Minimum Alias Confidence"; ui_tooltip = "Small floor added to the grid/brick detector to avoid dead zones in the risk map."; > = 0.02;
uniform float StaticSoftAmount < ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01; ui_label = "Static Anti-Shimmer Softness"; ui_tooltip = "Amount of gentle fallback smoothing when adaptive filtering is not triggered."; > = 0.05;

// ---- Adaptive filtering ----
uniform float AnisoStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.1; ui_label = "Directional Filter Strength"; ui_tooltip = "Overall intensity of the adaptive directional filter. Higher values reduce shimmer more, but may soften fine edges."; > = 1.35;
uniform float GridFloorStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.01; ui_label = "Grid Detector Floor"; ui_tooltip = "Minimum confidence for the geometric instability detector."; > = 0.005;
uniform float TensorMinimumStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Tensor Minimum Influence"; ui_tooltip = "Minimum amount of filtering applied when the structure tensor confidence is low."; > = 0.40;
uniform float RiskThreshold < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Risk Trigger Threshold"; ui_tooltip = "Minimum risk required to activate the directional filter. Below this value, only the fallback softness is used."; > = 0.06;
uniform float AliasResponseSharpness < ui_type = "slider"; ui_min = 0.5; ui_max = 5.0; ui_step = 0.1; ui_label = "Alias Response Curve"; ui_tooltip = "Controls how quickly the filter ramps up as aliasing confidence increases."; > = 2.0;
uniform float TapActivation < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Tap Activation Threshold"; ui_tooltip = "Risk level required to activate extra directional taps."; > = 0.60;

// ---- Surgical spatial filter v2.5n ----
uniform float SurgicalRangeSigma < ui_type = "slider"; ui_min = 0.02; ui_max = 0.35; ui_step = 0.005; ui_label = "Surgical Range Sigma"; ui_tooltip = "Color/luma tolerance for the edge-aware spatial filter. Lower values preserve edges more, higher values smooth shimmer more."; > = 0.105;
uniform float SurgicalEdgeProtection < ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.05; ui_label = "Surgical Edge Protection"; ui_tooltip = "How strongly the filter avoids bleeding across strong tensor edges."; > = 1.00;
uniform float SurgicalNormalLeak < ui_type = "slider"; ui_min = 0.0; ui_max = 0.60; ui_step = 0.01; ui_label = "Surgical Normal Leak"; ui_tooltip = "Small controlled amount of blur across the edge normal. Helps moire and stair-steps, but too much can soften geometry."; > = 0.12;
uniform float SurgicalSubpixelPhase < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Surgical Subpixel Phase"; ui_tooltip = "Half-pixel phase taps along the structure direction. Very useful against subpixel shimmer."; > = 0.55;
uniform float SurgicalDepthProtection < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Surgical Depth Protection"; ui_tooltip = "Reject blur taps across depth discontinuities. Set lower if the game depth buffer is unreliable."; > = 0.65;
uniform float SurgicalLumaPreservation < ui_type = "slider"; ui_min = 0.0; ui_max = 0.60; ui_step = 0.01; ui_label = "Surgical Luma Preservation"; ui_tooltip = "Restores a small amount of local luminance after spatial filtering to avoid dull/dark output."; > = 0.20;

// ---- Depth weighting ----
uniform float DepthActivationCenter < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Depth Midpoint"; ui_tooltip = "Center point of the depth weighting curve."; > = 0.3;
uniform float DepthSoftness < ui_type = "slider"; ui_min = 0.01; ui_max = 0.5; ui_step = 0.01; ui_label = "Depth Softness"; ui_tooltip = "Width of the depth weighting transition."; > = 0.15;
uniform float DepthMaxWeight < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Depth Max Weight"; ui_tooltip = "Maximum contribution of the depth detector."; > = 0.45;

// ---- Periodicity ----
uniform bool UsePeriodicity < ui_label = "Use Periodicity Detector"; ui_tooltip = "Enable the periodicity detector for repeated high-frequency patterns."; > = true;
uniform float PeriodicitySensitivity < ui_type = "slider"; ui_min = 0.5; ui_max = 20.0; ui_step = 0.5; ui_label = "Periodicity Sensitivity"; ui_tooltip = "How sensitive the periodicity detector should be to repeating structures."; > = 4.0;

// ---- Risk weights ----
uniform float W_GridBrick < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Grid-Brick"; ui_tooltip = "Contribution of sampling-phase divergence to the final risk map."; > = 0.45;
uniform float W_Temporal  < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Temporal"; ui_tooltip = "Contribution of temporal instability to the final risk map."; > = 0.25;
uniform float W_Periodic  < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Periodicity"; ui_tooltip = "Contribution of repeating high-frequency structures to the final risk map."; > = 0.20;
uniform float W_Depth     < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Depth"; ui_tooltip = "Contribution of the depth-based prioritization to the final risk map."; > = 0.05;

// ---- Temporal Neighborhood Tuning ----
uniform float TemporalColorTolerance < ui_type = "slider"; ui_min = 0.5; ui_max = 10.0; ui_step = 0.5; ui_label = "Temporal Color Tolerance"; ui_tooltip = "Softness of the color match. Higher values accept more lighting/color changes from the history."; > = 3.0;
uniform float TemporalDirEnforcement < ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.1; ui_label = "Temporal Tensor Enforcement"; ui_tooltip = "How strictly the temporal search follows the structure tensor direction."; > = 1.0;
uniform float TemporalCenterBias < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Temporal Center Importance"; ui_tooltip = "Baseline importance given to the exact center pixel of the search grid. Anchors the match to prevent drifting."; > = 0.4;

// ---- Temporal History Depth ----
uniform int HistoryDepth < ui_type = "slider"; ui_min = 0; ui_max = 120; ui_step = 1; ui_label = "Temporal History Depth (Frames)"; ui_tooltip = "Target frames to accumulate. 30 is a balanced default for 60fps gameplay. Higher values reduce shimmer more but increase temporal persistence and ghosting."; > = 30;

// ---- Phase-Aware Moire Suppression v2.5o ----
uniform bool UsePhaseMoireSuppression < ui_label = "Use Phase-Aware Moire Suppression"; ui_tooltip = "Detects A/B/A temporal alternation on high-frequency patterns and locally blends phases to reduce moire shimmer."; > = true;
uniform float PhaseMoireStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Phase Moire Strength"; ui_tooltip = "How strongly the shader suppresses detected alternating A/B/A moire patterns."; > = 0.42;
uniform float PhaseAlternationSensitivity < ui_type = "slider"; ui_min = 0.20; ui_max = 2.00; ui_step = 0.05; ui_label = "Phase Alternation Sensitivity"; ui_tooltip = "Sensitivity of the A/B/A alternating pattern detector. Higher values detect weaker temporal phase alternation."; > = 1.00;
uniform float PhaseMotionRejection < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Phase Motion Rejection"; ui_tooltip = "Rejects phase blending when all recent frames disagree, which usually means camera motion, parallax or disocclusion."; > = 0.70;
uniform float PhaseOutlierRejection < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Phase Outlier Rejection"; ui_tooltip = "Rejects isolated one-frame temporal outliers using a small temporal median. Useful for pop-in blocks/fireflies, but too much may ghost."; > = 0.22;
uniform float PhaseRiskGate < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Phase Risk Gate"; ui_tooltip = "Minimum risk contribution required before phase-aware moire suppression becomes active."; > = 0.10;

// ==============
// BEGIN
// ==============
float3 GetColor(float2 uv) { return tex2D(ReShade::BackBuffer, uv).rgb; }
float GetLuma(float3 col) { return dot(col, float3(0.299, 0.587, 0.114)); }

float3 ClampHistoryToSpatialNeighborhood(float2 uv, float3 histCol)
{
    float2 ts = BUFFER_RCP_SIZE;

    float3 c = tex2D(PhaseSpatialSampler, uv).rgb;

    float3 mn = c;
    float3 mx = c;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float3 s = tex2D(PhaseSpatialSampler, uv + float2(x, y) * ts).rgb;
            mn = min(mn, s);
            mx = max(mx, s);
        }
    }

    float3 range = mx - mn;
    float3 margin = range * 0.35 + float3(0.01, 0.01, 0.01);

    return clamp(histCol, mn - margin, mx + margin);
}


// =============================================================================
// GRID/BRICK DIVERGENCE
// =============================================================================
float ComputeGridBrickDivergence(float2 uv, float3 centerRGB, out float fireflyDamp)
{
    float2 ts = BUFFER_RCP_SIZE;

    float3 r1 = GetColor(uv + float2(1.0, 0.0) * ts);
    float3 l1 = GetColor(uv - float2(1.0, 0.0) * ts);
    float3 u1 = GetColor(uv + float2(0.0, 1.0) * ts);
    float3 d1 = GetColor(uv - float2(0.0, 1.0) * ts);

    float3 r2 = GetColor(uv + float2(2.0, 0.0) * ts);
    float3 l2 = GetColor(uv - float2(2.0, 0.0) * ts);
    float3 u2 = GetColor(uv + float2(0.0, 2.0) * ts);
    float3 d2 = GetColor(uv - float2(0.0, 2.0) * ts);

    float3 tr = GetColor(uv + float2(1.0, 1.0) * ts);
    float3 tl = GetColor(uv + float2(-1.0, 1.0) * ts);
    float3 br = GetColor(uv + float2(1.0, -1.0) * ts);
    float3 bl = GetColor(uv + float2(-1.0, -1.0) * ts);

    float lR1 = GetLuma(r1);
    float lL1 = GetLuma(l1);
    float lU1 = GetLuma(u1);
    float lD1 = GetLuma(d1);
    float lTR = GetLuma(tr);
    float lTL = GetLuma(tl);
    float lBR = GetLuma(br);
    float lBL = GetLuma(bl);

    float centerLuma = GetLuma(centerRGB);

    float neighborSum = lR1 + lL1 + lU1 + lD1 + lTR + lTL + lBR + lBL;
    float neighborMean = neighborSum * 0.125;

    float neighborMax = max(max(max(lR1, lL1), max(lU1, lD1)), max(max(lTR, lTL), max(lBR, lBL)));
    float neighborMin = min(min(min(lR1, lL1), min(lU1, lD1)), min(min(lTR, lTL), min(lBR, lBL)));
    float neighborRange = neighborMax - neighborMin;

    float spatialCap = max(neighborMax, neighborMean * 1.75 + 0.015);

    float supportRatio = saturate((neighborMean * 2.0 + neighborMax) / max(centerLuma, 0.0001));
    float isolatedPeak = 1.0 - smoothstep(0.35, 0.85, supportRatio);

    float brightNeighborhoodProtect = max(
        smoothstep(0.18, 0.55, neighborMean),
        smoothstep(0.35, 1.10, neighborMax)
    );

    float hardSpike = smoothstep(spatialCap * 1.10, spatialCap * 2.50 + 0.001, centerLuma);
    float microContrastSpike = smoothstep(0.08, 0.35, centerLuma - neighborMax) * (1.0 - smoothstep(0.12, 0.45, neighborRange));

    float fireflyMask = hardSpike * isolatedPeak * microContrastSpike * (1.0 - brightNeighborhoodProtect);

    float dampTarget = saturate(spatialCap / max(centerLuma, 0.0001));
    fireflyDamp = lerp(1.0, dampTarget, fireflyMask);

    float3 gA = (centerRGB + r2 + l2 + u2 + d2) * 0.2;
    float3 gB = (r1 + l1 + u1 + d1) * 0.25;
    float3 gC = (tr + tl + br + bl) * 0.25;

    float3 phaseAB = gA - gB;
    float3 phaseAC = gA - gC;
    float3 phaseBC = gB - gC;

    float variance = (dot(phaseAB, phaseAB) + dot(phaseAC, phaseAC) + dot(phaseBC, phaseBC)) * (1.0 / 6.0);

    return saturate(sqrt(variance) * GridSensitivity + GridFloorStrength);
}

// =============================================================================
// PERIODICITY DETECTOR
// =============================================================================
float ComputePeriodicity(float2 uv)
{
    float c  = GetLuma(GetColor(uv));
    float l1 = GetLuma(GetColor(uv - float2(1.0, 0.0) * BUFFER_RCP_SIZE));
    float r1 = GetLuma(GetColor(uv + float2(1.0, 0.0) * BUFFER_RCP_SIZE));
    float u1 = GetLuma(GetColor(uv - float2(0.0, 1.0) * BUFFER_RCP_SIZE));
    float d1 = GetLuma(GetColor(uv + float2(0.0, 1.0) * BUFFER_RCP_SIZE));
    float l2 = GetLuma(GetColor(uv - float2(2.0, 0.0) * BUFFER_RCP_SIZE));
    float r2 = GetLuma(GetColor(uv + float2(2.0, 0.0) * BUFFER_RCP_SIZE));
    float u2 = GetLuma(GetColor(uv - float2(0.0, 2.0) * BUFFER_RCP_SIZE));
    float d2 = GetLuma(GetColor(uv + float2(0.0, 2.0) * BUFFER_RCP_SIZE));
    float l4 = GetLuma(GetColor(uv - float2(4.0, 0.0) * BUFFER_RCP_SIZE));
    float r4 = GetLuma(GetColor(uv + float2(4.0, 0.0) * BUFFER_RCP_SIZE));
    float u4 = GetLuma(GetColor(uv - float2(0.0, 4.0) * BUFFER_RCP_SIZE));
    float d4 = GetLuma(GetColor(uv + float2(0.0, 4.0) * BUFFER_RCP_SIZE));

    float lapH = abs(l1 + r1 - 2.0 * c);
    float lapV = abs(u1 + d1 - 2.0 * c);
    float varH  = (abs(c - l2) + abs(c - r2)) * 0.5;
    float varV  = (abs(c - u2) + abs(c - d2)) * 0.5;
    float varH4 = (abs(c - l4) + abs(c - r4)) * 0.5;
    float varV4 = (abs(c - u4) + abs(c - d4)) * 0.5;
    float persistH = (1.0 - saturate(varH * 8.0)) * (1.0 - saturate(varH4 * 8.0));
    float persistV = (1.0 - saturate(varV * 8.0)) * (1.0 - saturate(varV4 * 8.0));

    float rawPeriodicity = max(lapH * persistH, lapV * persistV);
    float shaped = pow(saturate(rawPeriodicity * PeriodicitySensitivity), 3.0);
    return smoothstep(0.10, 0.35, shaped);
}

// =============================================================================
// STRUCTURE TENSOR
// =============================================================================
void ComputeStructureTensorDirection(float2 uv, out float2 blurDir, out float tensorConfidence)
{
    float2 ts = BUFFER_RCP_SIZE;
    float Jxx = 0.0, Jyy = 0.0, Jxy = 0.0;
    for(int x=-1; x<=1; x++) {
        for(int y=-1; y<=1; y++) {
            float2 off = float2(x, y) * ts;
            float g1 = GetLuma(GetColor(uv + off - float2(1, 0) * ts));
            float g2 = GetLuma(GetColor(uv + off + float2(1, 0) * ts));
            float g3 = GetLuma(GetColor(uv + off - float2(0, 1) * ts));
            float g4 = GetLuma(GetColor(uv + off + float2(0, 1) * ts));
            float gx = (g2 - g1) * 0.5;
            float gy = (g4 - g3) * 0.5;
            Jxx += gx * gx; Jyy += gy * gy; Jxy += gx * gy;
        }
    }
    Jxx /= 9.0; Jyy /= 9.0; Jxy /= 9.0;
    float trace = Jxx + Jyy;
    float det = Jxx * Jyy - Jxy * Jxy;
    tensorConfidence = saturate((trace * trace - 4.0 * det) / (trace * trace + 0.0001));
    float theta = 0.5 * atan2(2.0 * Jxy, Jxx - Jyy);
    float2 edgeDir = float2(cos(theta), sin(theta));
    blurDir = normalize(float2(-edgeDir.y, edgeDir.x));
}

float DASR_DepthTapWeight(float centerDepth, float2 sampleUV)
{
    float sampleDepth = ReShade::GetLinearizedDepth(sampleUV);
    float d = abs(sampleDepth - centerDepth);

    float depthReject = 1.0 - smoothstep(0.0015, 0.0300, d);

    return lerp(1.0, depthReject, SurgicalDepthProtection);
}

float DASR_RangeTapWeight(float3 centerCol, float3 sampleCol, float rangeSigma)
{
    float centerL = GetLuma(centerCol);
    float sampleL = GetLuma(sampleCol);

    float lDiff = abs(centerL - sampleL);
    float cDiff = distance(centerCol, sampleCol);

    float s = max(rangeSigma, 0.0001);

    float lumaW = exp(-(lDiff * lDiff) / (s * s));
    float colorW = exp(-(cDiff * cDiff) / (s * s * 6.0));

    return lumaW * colorW;
}

void DASR_AccumSurgicalTap(
    inout float3 sum,
    inout float wSum,
    float2 uv,
    float2 offsetPixels,
    float baseWeight,
    float3 centerCol,
    float centerDepth,
    float rangeSigma
)
{
    float2 sampleUV = uv + offsetPixels * BUFFER_RCP_SIZE;
    float3 sampleCol = GetColor(sampleUV);

    float rangeW = DASR_RangeTapWeight(centerCol, sampleCol, rangeSigma);
    float depthW = DASR_DepthTapWeight(centerDepth, sampleUV);

    float w = baseWeight * rangeW * depthW;

    sum += sampleCol * w;
    wSum += w;
}

float DASR_NormalizedTemporalDiff(float3 a, float3 b)
{
    float la = GetLuma(a);
    float lb = GetLuma(b);

    float lDiff = abs(la - lb);
    float cDiff = distance(a, b);

    float lumNorm = lDiff / (0.035 + max(la, lb));
    float rgbNorm = cDiff / (0.080 + max(length(a), length(b)));

    return saturate(lerp(rgbNorm, lumNorm, 0.65));
}

float3 DASR_Median3(float3 a, float3 b, float3 c)
{
    return a + b + c - min(a, min(b, c)) - max(a, max(b, c));
}

float3 DASR_ClampToCurrentSpatialNeighborhood(float2 uv, float3 col)
{
    float2 ts = BUFFER_RCP_SIZE;

    float3 center = tex2D(SpatialSampler, uv).rgb;
    float3 mn = center;
    float3 mx = center;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float3 s = tex2D(SpatialSampler, uv + float2(x, y) * ts).rgb;
            mn = min(mn, s);
            mx = max(mx, s);
        }
    }

    float3 range = mx - mn;
    float3 margin = range * 0.30 + float3(0.008, 0.008, 0.008);

    return clamp(col, mn - margin, mx + margin);
}

// =============================================================================
// PASS 1: THE ORACLE
// =============================================================================
float4 PS_RiskMap(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 centerCol = GetColor(uv);

    float fireflyDamp = 1.0;
    float gridBrickDiv = ComputeGridBrickDivergence(uv, centerCol, fireflyDamp);

    float periodicity = UsePeriodicity ? ComputePeriodicity(uv) : 0.0;

    float depthWeight =
        smoothstep(
            DepthActivationCenter - DepthSoftness,
            DepthActivationCenter + DepthSoftness,
            ReShade::GetLinearizedDepth(uv)
        ) * DepthMaxWeight;

    float riskTemporal = 0.0;
    float2 motionOffset = float2(0.0, 0.0);

    // =========================================================================
    // TEMPORAL RISK v2.5
    // =========================================================================
    if (FrameCount > 1 && HistoryDepth > 0) {
        float2 blurDir;
        float tensorConfidence;
        ComputeStructureTensorDirection(uv, blurDir, tensorConfidence);

        float bestScore = 999.0;
        float bestRawDiff = 999.0;
        float bestLumaDiff = 999.0;
        float2 bestOffset = float2(0.0, 0.0);

        float centerLuma = GetLuma(centerCol);

        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 offset = float2(x, y) * BUFFER_RCP_SIZE;

                float3 histCol = tex2D(HistoryPrevSampler, uv + offset).rgb;

                float histLuma = GetLuma(histCol);

                float diffRGB = distance(centerCol, histCol);
                float diffLuma = abs(centerLuma - histLuma);

                float lumNorm = diffLuma / (0.035 + max(centerLuma, histLuma));
                float rgbNorm = diffRGB / (0.080 + max(length(centerCol), length(histCol)));

                float rawDiff = lerp(rgbNorm, lumNorm, 0.65);

                float softDiff = 1.0 - exp(-rawDiff * TemporalColorTolerance);

                float2 sampleDir = (x == 0 && y == 0) ? float2(0.0, 0.0) : normalize(float2(x, y));
                float alignment = (x == 0 && y == 0) ? 1.0 : abs(dot(sampleDir, blurDir));

                float dirPenalty =
                    lerp(
                        0.0,
                        (1.0 - alignment) * (1.0 - alignment),
                        tensorConfidence * TemporalDirEnforcement
                    );

                float centerBonus = (x == 0 && y == 0) ? -TemporalCenterBias : 0.0;

                float score = softDiff + dirPenalty + centerBonus;

                if (!UseMotionHeuristic && (x != 0 || y != 0)) {
                    score += 100.0;
                }

                if (score < bestScore) {
                    bestScore = score;
                    bestRawDiff = rawDiff;
                    bestLumaDiff = diffLuma;
                    bestOffset = offset;
                }
            }
        }

        motionOffset = bestOffset;

        // ---------------------------------------------------------------------
        // Local HF gate:
        // ---------------------------------------------------------------------
        float2 ts = BUFFER_RCP_SIZE;

        float lR = GetLuma(GetColor(uv + float2(1, 0) * ts));
        float lL = GetLuma(GetColor(uv - float2(1, 0) * ts));
        float lU = GetLuma(GetColor(uv + float2(0, 1) * ts));
        float lD = GetLuma(GetColor(uv - float2(0, 1) * ts));

        float localContrast =
            (abs(centerLuma - lR) +
             abs(centerLuma - lL) +
             abs(centerLuma - lU) +
             abs(centerLuma - lD)) * 0.25;

        float localHFGate =
            saturate(
                gridBrickDiv * 0.65 +
                periodicity * 0.55 +
                smoothstep(0.015, 0.160, localContrast) * 0.45 +
                MinimumAliasConfidence
            );

        // ---------------------------------------------------------------------
        // Motion/disocclusion rejection:
        // ---------------------------------------------------------------------
        float motionReject = smoothstep(0.18, 0.62, bestRawDiff);

        float temporalMicro =
            smoothstep(0.012, 0.145, bestRawDiff) *
            (1.0 - motionReject);

        float temporalSignal =
            pow(saturate(bestRawDiff * TemporalSensitivity * 0.55), 1.35) *
            temporalMicro *
            localHFGate;

        // Fireflyes
        float fireflySignal = 1.0 - fireflyDamp;

        riskTemporal = saturate(max(temporalSignal, fireflySignal));
    }

    float aliasStrength = saturate(gridBrickDiv * 0.60 + riskTemporal * 0.40);

    float currentAliasStrength = tex2D(HistoryPrevSampler, uv).a;

    aliasStrength =
        (currentAliasStrength > aliasStrength)
        ? lerp(currentAliasStrength, aliasStrength, 0.15)
        : lerp(currentAliasStrength, aliasStrength, 0.35);

    float weightSum = max(W_GridBrick + W_Temporal + W_Periodic + W_Depth, 0.001);

    float finalRisk =
        saturate(
            (
                gridBrickDiv * W_GridBrick +
                riskTemporal * W_Temporal +
                periodicity * W_Periodic +
                depthWeight * W_Depth
            ) / weightSum
        );

    if (DebugMode == 1) return float4(ReShade::GetLinearizedDepth(uv).xxx, 1.0);
    if (DebugMode == 2) return float4(depthWeight.xxx, 1.0);
    if (DebugMode == 3) return float4(gridBrickDiv.xxx, 1.0);
    if (DebugMode == 4) return float4(periodicity.xxx, 1.0);
    if (DebugMode == 5) return float4(riskTemporal.xxx, 1.0);
    if (DebugMode == 6) return float4(finalRisk, aliasStrength, riskTemporal, 1.0);

    if (DebugMode == 9) {
        float m = length(motionOffset) / length(BUFFER_RCP_SIZE);
        return float4(m.xxx, 1.0);
    }

    return float4(finalRisk, aliasStrength, periodicity, fireflyDamp);
}

// =============================================================================
// PASS 2: THE SURGEON
// =============================================================================
float4 PS_AnisotropicLowPass(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if ((DebugMode >= 1 && DebugMode <= 6) || DebugMode == 9) return tex2D(RiskMapSampler, uv);

    float4 riskData = tex2D(RiskMapSampler, uv);

    float risk = riskData.r;
    float aliasStrength = riskData.g;
    float periodicity = riskData.b;
    float fireflyDamp = riskData.a;

    if (DebugMode == 7) {
        float2 dbgDir;
        float dbgTensorConfidence;
        ComputeStructureTensorDirection(uv, dbgDir, dbgTensorConfidence);
        return float4(abs(dbgDir), 0.0, 1.0);
    }

    if (DebugMode == 8) {
        int dbgMaxRings =
            (risk > TapActivation)
            ? 3
            : ((risk > TapActivation * 0.5) ? 2 : 1);

        float tapNorm = float(dbgMaxRings) / 3.0;
        return float4(tapNorm.xxx, 1.0);
    }

    float3 currentCol = GetColor(uv);

    // =====================================================================
    // 1. Firefly pre-clip
    // =====================================================================
    if (fireflyDamp < 1.0) {
        float3 avgNeighbors = (
            GetColor(uv + BUFFER_RCP_SIZE * float2(1, 0)) +
            GetColor(uv - BUFFER_RCP_SIZE * float2(1, 0)) +
            GetColor(uv + BUFFER_RCP_SIZE * float2(0, 1)) +
            GetColor(uv - BUFFER_RCP_SIZE * float2(0, 1))
        ) * 0.25;

        currentCol = lerp(currentCol, avgNeighbors, 1.0 - fireflyDamp);
    }

    // =====================================================================
    // 2. Low-risk fallback: bilateral, lightweight, no blur.
    // =====================================================================
    if (risk < RiskThreshold) {
        float centerDepth = ReShade::GetLinearizedDepth(uv);
        float rangeSigma = SurgicalRangeSigma * 0.85;

        float3 sum = currentCol;
        float wSum = 1.0;

        DASR_AccumSurgicalTap(sum, wSum, uv, float2( 1.0,  0.0), StaticSoftAmount, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, float2(-1.0,  0.0), StaticSoftAmount, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, float2( 0.0,  1.0), StaticSoftAmount, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, float2( 0.0, -1.0), StaticSoftAmount, currentCol, centerDepth, rangeSigma);

        float3 soft = sum / max(wSum, 0.0001);

        return float4(soft, 1.0);
    }

    // =====================================================================
    // 3. Structure direction
    // =====================================================================
    float2 dir;
    float tensorConfidence;
    ComputeStructureTensorDirection(uv, dir, tensorConfidence);

    if (DebugMode == 7) return float4(abs(dir), 0.0, 1.0);

    float2 tangent = normalize(dir);
    float2 normal = normalize(float2(-tangent.y, tangent.x));

    // =====================================================================
    // 4. Strength model
    // =====================================================================
    float tensorInfluence = lerp(TensorMinimumStrength, 1.0, tensorConfidence);

    float rawStrength =
        pow(aliasStrength, AliasResponseSharpness) *
        AnisoStrength *
        tensorInfluence;

    float strength = saturate(rawStrength);

    int maxRings =
        (risk > TapActivation)
        ? 3
        : ((risk > TapActivation * 0.5) ? 2 : 1);

    if (DebugMode == 8) {
        float tapNorm = float(maxRings) / 3.0;
        return float4(tapNorm.xxx, 1.0);
    }

    // =====================================================================
    // 5. Adaptive bilateral/elliptical parameters
    // =====================================================================
    float centerDepth = ReShade::GetLinearizedDepth(uv);

    float rangeSigma =
        SurgicalRangeSigma *
        lerp(1.25, 0.70, saturate(tensorConfidence * SurgicalEdgeProtection));

    float normalLeak =
        SurgicalNormalLeak *
        (1.0 - saturate(tensorConfidence * SurgicalEdgeProtection * 0.85));

    normalLeak += periodicity * 0.08 * (1.0 - tensorConfidence * 0.50);
    normalLeak = saturate(normalLeak);

    float phaseGain = SurgicalSubpixelPhase * strength;

    float diagonalGain =
        periodicity *
        strength *
        lerp(0.22, 0.10, tensorConfidence);

    // =====================================================================
    // 6. Surgical elliptical accumulation
    // =====================================================================
    float3 sum = currentCol;
    float wSum = 1.0;

    // ---- Half-pixel phase taps along tangent ----
    DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 0.50, 0.42 * phaseGain, currentCol, centerDepth, rangeSigma);
    DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 0.50, 0.42 * phaseGain, currentCol, centerDepth, rangeSigma);

    // ---- Main tangent taps ----
    DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 1.00, 0.82 * strength, currentCol, centerDepth, rangeSigma);
    DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 1.00, 0.82 * strength, currentCol, centerDepth, rangeSigma);

    if (maxRings >= 2) {
        DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 1.65, 0.42 * strength, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 1.65, 0.42 * strength, currentCol, centerDepth, rangeSigma);

        DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 2.35, 0.22 * strength, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 2.35, 0.22 * strength, currentCol, centerDepth, rangeSigma);
    }

    if (maxRings >= 3) {
        DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 3.10, 0.115 * strength, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 3.10, 0.115 * strength, currentCol, centerDepth, rangeSigma);
    }

    // ---- Controlled normal taps ----
    DASR_AccumSurgicalTap(sum, wSum, uv,  normal * 0.70, 0.55 * strength * normalLeak, currentCol, centerDepth, rangeSigma);
    DASR_AccumSurgicalTap(sum, wSum, uv, -normal * 0.70, 0.55 * strength * normalLeak, currentCol, centerDepth, rangeSigma);

    if (maxRings >= 2) {
        DASR_AccumSurgicalTap(sum, wSum, uv,  normal * 1.20, 0.24 * strength * normalLeak, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -normal * 1.20, 0.24 * strength * normalLeak, currentCol, centerDepth, rangeSigma);
    }

    // ---- Diagonal phase taps for periodic structures ----
    if (maxRings >= 2) {
        DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 1.00 + normal * 0.45, 0.30 * diagonalGain, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv,  tangent * 1.00 - normal * 0.45, 0.30 * diagonalGain, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 1.00 + normal * 0.45, 0.30 * diagonalGain, currentCol, centerDepth, rangeSigma);
        DASR_AccumSurgicalTap(sum, wSum, uv, -tangent * 1.00 - normal * 0.45, 0.30 * diagonalGain, currentCol, centerDepth, rangeSigma);
    }

    float3 filteredCol = sum / max(wSum, 0.0001);

    // =====================================================================
    // 7. Final spatial blend
    // =====================================================================
    float spatialBlend =
        saturate(
            strength * lerp(0.52, 0.82, risk) +
            periodicity * 0.10 +
            (1.0 - fireflyDamp) * 0.25
        );

    float3 finalColor = lerp(currentCol, filteredCol, spatialBlend);

    // =====================================================================
    // 8. Luma preservation leggera
    // =====================================================================
    float currentLum = GetLuma(currentCol);
    float finalLum = GetLuma(finalColor);

    float lumRatio = currentLum / max(finalLum, 0.0001);
    lumRatio = clamp(lumRatio, 0.88, 1.14);

    finalColor *= lerp(1.0, lumRatio, SurgicalLumaPreservation);

    return float4(finalColor, 1.0);
}

// =============================================================================
// PASS 2B: PHASE-AWARE MOIRE SUPPRESSION
// =============================================================================
float4 PS_PhaseMoireSuppression(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (DebugMode >= 1 && DebugMode <= 9) {
        return tex2D(SpatialSampler, uv);
    }

    float3 currentCol = tex2D(SpatialSampler, uv).rgb;

    if (!UsePhaseMoireSuppression || FrameCount <= 2) {
        if (DebugMode == 10 || DebugMode == 11) return float4(0.0, 0.0, 0.0, 1.0);
        return float4(currentCol, 1.0);
    }

    float4 riskData = tex2D(RiskMapSampler, uv);

    float risk = riskData.r;
    float aliasStrength = riskData.g;
    float periodicity = riskData.b;
    float fireflyDamp = riskData.a;

    float3 prev1Center = tex2D(SpatialPrevSampler, uv).rgb;
    float3 prev2Center = tex2D(SpatialPrev2Sampler, uv).rgb;

    float d01Center = DASR_NormalizedTemporalDiff(currentCol, prev1Center);
    float d02Center = DASR_NormalizedTemporalDiff(currentCol, prev2Center);
    float d12Center = DASR_NormalizedTemporalDiff(prev1Center, prev2Center);

    // =========================================================================
    // LOCAL PHASE SEARCH
    // -------------------------------------------------------------------------
    // look for the best match in a small 3x3:
    // - bestD01 = how much the current frame matches the previous frame
    // - bestD02 = how much the current frame matches the frame from two frames ago
    //
    // Ideal A/B/A:
    // - bestD02 low  -> current looks like prev2
    // - bestD01 high -> current does NOT look like prev1
    // =========================================================================
    float bestD01 = 999.0;
    float bestD02 = 999.0;

    float2 bestOff01 = float2(0.0, 0.0);
    float2 bestOff02 = float2(0.0, 0.0);

    float3 bestPrev1Col = prev1Center;
    float3 bestPrev2Col = prev2Center;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 offset = float2(x, y) * BUFFER_RCP_SIZE;

            float3 p1 = tex2D(SpatialPrevSampler, uv + offset).rgb;
            float3 p2 = tex2D(SpatialPrev2Sampler, uv + offset).rgb;

            float d1 = DASR_NormalizedTemporalDiff(currentCol, p1);
            float d2 = DASR_NormalizedTemporalDiff(currentCol, p2);

            float offsetPenalty = dot(float2(x, y), float2(x, y)) * 0.006;

            if (d1 + offsetPenalty < bestD01) {
                bestD01 = d1;
                bestOff01 = offset;
                bestPrev1Col = p1;
            }

            if (d2 + offsetPenalty < bestD02) {
                bestD02 = d2;
                bestOff02 = offset;
                bestPrev2Col = p2;
            }
        }
    }

    float riskGate =
        saturate(
            (risk - PhaseRiskGate) / max(1.0 - PhaseRiskGate, 0.0001)
        );

    riskGate =
        saturate(
            riskGate * 0.65 +
            aliasStrength * 0.30 +
            periodicity * 0.45
        );

    // =========================================================================
    // A/B/A PHASE DETECTOR v2
    // =========================================================================
    float sensitivity = PhaseAlternationSensitivity;

    float sameAsPrev2 =
        1.0 - smoothstep(0.055 / sensitivity, 0.240 / sensitivity, bestD02);

    float differentFromPrev1 =
        smoothstep(0.050 / sensitivity, 0.260 / sensitivity, bestD01);

    float prev2Preference =
        smoothstep(0.010, 0.160, bestD01 - bestD02);

    float centerTemporalEnergy =
        smoothstep(0.035 / sensitivity, 0.240 / sensitivity, max(d01Center, d12Center));

    float strictSamePhase =
        1.0 - smoothstep(0.045 / sensitivity, 0.170 / sensitivity, d02Center);

    float strictOppositePhase =
        smoothstep(0.055 / sensitivity, 0.260 / sensitivity, min(d01Center, d12Center));

    float strictABA = strictSamePhase * strictOppositePhase;

    float localABA =
        sameAsPrev2 *
        differentFromPrev1 *
        prev2Preference *
        centerTemporalEnergy;

    float temporalBeat =
        sameAsPrev2 *
        centerTemporalEnergy *
        smoothstep(0.035 / sensitivity, 0.220 / sensitivity, d01Center);

    float phaseAlternation =
        saturate(
            max(
                max(localABA, strictABA * 0.75),
                temporalBeat * 0.35
            )
        );


    // =========================================================================
    // MOTION / DISOCCLUSION REJECTION
    // =========================================================================
    float allFramesDisagreeLocal =
        smoothstep(0.160, 0.520, min(bestD01, bestD02));

    // If prev1 matches very well locally, it is more likely normal camera motion.
    float prev1MotionMatch =
        1.0 - smoothstep(0.040, 0.150, bestD01);

    float motionReject =
        saturate(
            allFramesDisagreeLocal * PhaseMotionRejection +
            prev1MotionMatch * 0.35
        );

    float phaseMoireMask =
        phaseAlternation *
        (1.0 - motionReject) *
        riskGate *
        PhaseMoireStrength;

    phaseMoireMask = saturate(phaseMoireMask);

    // =========================================================================
    // PHASE AVERAGE
    // -------------------------------------------------------------------------
    // use prev1Center as phase B.
    // do not use bestPrev1Col directly, because if the local match finds
    // nearby geometry during camera movement it could introduce ghosting.
    // =========================================================================
    float3 phaseAverage = (currentCol + prev1Center) * 0.5;

    phaseAverage = DASR_ClampToCurrentSpatialNeighborhood(uv, phaseAverage);

    float3 stabilizedCol = lerp(currentCol, phaseAverage, phaseMoireMask);

    // =========================================================================
    // CURRENT OUTLIER REJECTION
    // -------------------------------------------------------------------------
    // Pattern:
    // prev1 ≈ prev2
    // current is different from both
    //
    // This is more similar to a block/pop/firefly one-frame.
    // Here we keep a more cautious logic.
    // =========================================================================
    float prevsAgree =
        1.0 - smoothstep(0.040, 0.155, d12Center);

    float currentDisagrees =
        smoothstep(0.090, 0.360, min(d01Center, d02Center));

    float outlierRaw = prevsAgree * currentDisagrees;

    float outlierGate =
        saturate(
            (1.0 - fireflyDamp) * 0.85 +
            periodicity * 0.25 +
            aliasStrength * 0.20
        );

    float outlierMask =
        outlierRaw *
        outlierGate *
        riskGate *
        PhaseOutlierRejection *
        (1.0 - motionReject);

    outlierMask = saturate(outlierMask);

    float3 temporalMedian = DASR_Median3(currentCol, prev1Center, prev2Center);
    temporalMedian = DASR_ClampToCurrentSpatialNeighborhood(uv, temporalMedian);

    stabilizedCol = lerp(stabilizedCol, temporalMedian, outlierMask);

    // =========================================================================
    // DEBUG
    // =========================================================================
    if (DebugMode == 10) {
        float dbgTemporalEnergy = centerTemporalEnergy;
        float dbgABA = saturate(max(localABA, strictABA));
        float dbgCandidate = phaseAlternation * riskGate * (1.0 - motionReject);

        return float4(
            saturate(float3(
                dbgTemporalEnergy * 1.4,
                dbgABA * 3.0,
                dbgCandidate * 8.0
            )),
            1.0
        );
    }


    if (DebugMode == 11) {
        float debugOutlier =
            outlierRaw *
            outlierGate *
            riskGate *
            (1.0 - motionReject);

        return float4(saturate(debugOutlier * 8.0).xxx, 1.0);
    }

    return float4(stabilizedCol, 1.0);
}

// =============================================================================
// PASS 3: HISTORY COPY
// =============================================================================
float4 PS_HistoryCopy(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (DebugMode != 0 && DebugMode != 5 && DebugMode != 6 && DebugMode != 9) {
        return tex2D(HistoryPrevSampler, uv);
    }

    float3 currentCol = tex2D(PhaseSpatialSampler, uv).rgb;
    float4 riskData = tex2D(RiskMapSampler, uv);
    float currentAliasStrength = riskData.g;
    float fireflyDamp = riskData.a;

    if (HistoryDepth <= 0) {
        return float4(currentCol, currentAliasStrength);
    }

    float3 prevHistCol = tex2D(HistoryPrevSampler, uv).rgb;

    prevHistCol = ClampHistoryToSpatialNeighborhood(uv, prevHistCol);

    float diffRGB = distance(currentCol, prevHistCol);
    float diffLuma = abs(GetLuma(currentCol) - GetLuma(prevHistCol));
    float motionAmount = smoothstep(0.035, 0.22, max(diffRGB, diffLuma * 2.0));

    motionAmount *= lerp(0.55, 1.0, fireflyDamp);

    float baseAlpha = saturate(1.0 / float(max(HistoryDepth, 1)));
    float dynamicAlpha = lerp(baseAlpha, 0.55, motionAmount);
    float3 smoothedHistory = lerp(prevHistCol, currentCol, dynamicAlpha);

    return float4(smoothedHistory, currentAliasStrength);
}

// =============================================================================
// PASS 4: FINAL OUTPUT (phase-spatial + temporal)
// =============================================================================
float4 PS_FinalOutput(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (DebugMode >= 1 && DebugMode <= 11) return tex2D(PhaseSpatialSampler, uv);

    float3 spatialCol = tex2D(PhaseSpatialSampler, uv).rgb;

    float4 histData = tex2D(HistorySampler, uv);
    float3 histCol = histData.rgb;

    float4 riskData = tex2D(RiskMapSampler, uv);

    float risk = riskData.r;
    float aliasStrength = riskData.g;
    float periodicity = riskData.b;
    float fireflyDamp = riskData.a;

    histCol = ClampHistoryToSpatialNeighborhood(uv, histCol);

    float riskBlend = smoothstep(0.10, 0.70, risk) * 0.58;
    float periodicPush = periodicity * 0.18;
    float fireflyPush = (1.0 - fireflyDamp) * 0.42;

    float temporalBlend = saturate(riskBlend + periodicPush + fireflyPush);

    float histConfidence = saturate(float(FrameCount) / 20.0);
    temporalBlend *= histConfidence;

    temporalBlend = min(temporalBlend, 0.68);

    float3 finalColor = lerp(spatialCol, histCol, temporalBlend);

    float spatialLum = GetLuma(spatialCol);
    float finalLum = GetLuma(finalColor);

    float lumRatio = spatialLum / max(finalLum, 0.0001);
    lumRatio = clamp(lumRatio, 0.88, 1.16);

    finalColor *= lerp(1.0, lumRatio, 0.25);

    return float4(finalColor, 1.0);
}

// =============================================================================
// PASS 4B
// =============================================================================
float4 PS_CopyHistoryToPrev(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(HistorySampler, uv);
}

float4 PS_CopySpatialPrevToPrev2(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(SpatialPrevSampler, uv);
}

float4 PS_CopySpatialToPrev(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (DebugMode >= 1 && DebugMode <= 9) {
        return tex2D(SpatialPrev2Sampler, uv);
    }

    return tex2D(SpatialSampler, uv);
}

// =============================================================================
// TECHNIQUE
// =============================================================================
technique DASR_v2_5o < ui_tooltip = "DASR v2.5o (Differential Adaptive Shimmer Reductor)"; > {
    pass RiskMapPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_RiskMap;
        RenderTarget = RiskMapBuffer;
    }

    pass SurgicalSpatialPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_AnisotropicLowPass;
        RenderTarget = SpatialBuffer;
    }

    pass PhaseMoirePass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_PhaseMoireSuppression;
        RenderTarget = PhaseSpatialBuffer;
    }

    pass HistoryCopyPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_HistoryCopy;
        RenderTarget = HistoryBuffer;
    }

    pass FinalOutputPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_FinalOutput;
    }

    pass PersistSpatialPrev2Pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CopySpatialPrevToPrev2;
        RenderTarget = SpatialPrev2Buffer;
    }

    pass PersistSpatialPrevPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CopySpatialToPrev;
        RenderTarget = SpatialPrevBuffer;
    }

    pass PersistHistoryPass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CopyHistoryToPrev;
        RenderTarget = HistoryPrevBuffer;
    }
}
