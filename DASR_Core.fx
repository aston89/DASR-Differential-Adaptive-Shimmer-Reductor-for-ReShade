// ============================================================================
// DASR-Core v0.7.1 
// Purpose: Lightweight and more effective version of DASR
// ============================================================================

#include "ReShade.fxh"

#define BUFFER_RCP_SIZE float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT)

// ---- Captured current frame for persistent RGB history -----------------------
// Detector/output taps read the original backbuffer directly while it is still
// unmodified, avoiding an extra half-float conversion in the Grid input.
texture2D CurrentColorBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D CurrentColorSampler
{
    Texture = CurrentColorBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// ---- Spatial Grid signature: R=Grid score, G/B/A=phase A/B/C luma --------
texture2D CurrentGridBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D CurrentGridSampler
{
    Texture = CurrentGridBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

texture2D PreviousGridBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D PreviousGridSampler
{
    Texture = PreviousGridBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// Experimental channels: R=original temporal residual, G/B=signed motion,
// A=motion confidence. This intentionally differs from the v0.4 frozen schema.
texture2D GridTemporalBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D GridTemporalSampler
{
    Texture = GridTemporalBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// Motion-conditioned temporal field. Reuses GridTemporalBuffer channels:
// R=original GridTemporal residual, G/B=estimated current-frame velocity (px/frame),
// A=confidence. A separate history stores only this field, never historical RGB.
texture2D PreviousMotionBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D PreviousMotionSampler
{
    Texture = PreviousMotionBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// Previous-frame linearized depth. Used only to validate pseudo-flow; current
// depth is read through ReShade.fxh. This history contains scalar depth only.
texture2D PreviousDepthBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = R16F;
};
sampler2D PreviousDepthSampler
{
    Texture = PreviousDepthBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// Two-frame raw color history. Alpha stores a negative frame stamp (RGB-only
// evidence otherwise); this detects stale buffers after enabling the effect mid-run.
// These samples are evidence only, never unconditional temporal accumulation.
texture2D PreviousColorBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D PreviousColorSampler
{
    Texture = PreviousColorBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

texture2D OlderColorBuffer
{
    Width = BUFFER_WIDTH;
    Height = BUFFER_HEIGHT;
    Format = RGBA16F;
};
sampler2D OlderColorSampler
{
    Texture = OlderColorBuffer;
    MinFilter = Point; MagFilter = Point; MipFilter = Point;
    AddressU = Clamp; AddressV = Clamp;
};

// ---- Original detector controls (same defaults and response curves) --------
uniform int FrameCount < source = "framecount"; >;

uniform int DebugView <
    ui_type = "combo";
    ui_label = "Debug visualization";
    ui_category = "Diagnostics";
    ui_tooltip = "Choose a named diagnostic view from the dropdown. Option indices stay compatible with earlier v0.7 presets.";
    ui_items =
        "0 - Original image (raw source)\0"
        "1 - Grid-Brick risk (vulnerable sampling)\0"
        "2 - Temporal residual (current vs previous)\0"
        "3 - Combined risk (grid x temporal)\0"
        "4 - Risk channels: R grid / G temporal / B combined\0"
        "5 - Motion map: R X / G Y / B confidence\0"
        "6 - Motion confidence (grayscale)\0"
        "7 - Chroma suppression mask\0"
        "8 - Luma suppression mask\0"
        "9 - Isolated outlier repair mask\0"
        "10 - Instability: R luma / G chroma / B outliers\0"
        "11 - Output change vs source (x4)\0"
        "12 - Corrected output (normal view)\0"
        "13 - Linearized depth (grayscale)\0"
        "14 - Depth boundary strength (grayscale)\0"
        "15 - Depth-match trust (grayscale)\0";
> = 12;

uniform float GridSensitivity <
    ui_type = "slider"; ui_min = 1.0; ui_max = 30.0; ui_step = 0.5;
    ui_label = "Grid Sensitivity";
    ui_category = "Grid & Temporal Detection";
> = 5.0;

uniform float TemporalThresholdLow <
    ui_type = "slider"; ui_min = 0.001; ui_max = 0.10; ui_step = 0.001;
    ui_label = "Temporal Threshold Low";
    ui_category = "Grid & Temporal Detection";
> = 0.018;

uniform float TemporalThresholdHigh <
    ui_type = "slider"; ui_min = 0.01; ui_max = 0.30; ui_step = 0.005;
    ui_label = "Temporal Threshold High";
    ui_category = "Grid & Temporal Detection";
> = 0.12;

uniform float LocalShiftPenalty <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.05; ui_step = 0.001;
    ui_label = "Local Shift Penalty";
    ui_category = "Grid & Temporal Detection";
> = 0.008;

// ---- C-only correction controls; none feeds back into the detector ---------
uniform float ChromaTemporalLow <
    ui_type = "slider"; ui_min = 0.001; ui_max = 0.04; ui_step = 0.001;
    ui_label = "Chroma Instability Low";
    ui_category = "C Correction";
> = 0.008;

uniform float ChromaTemporalHigh <
    ui_type = "slider"; ui_min = 0.01; ui_max = 0.12; ui_step = 0.002;
    ui_label = "Chroma Instability High";
    ui_category = "C Correction";
> = 0.055;

uniform float LumaTemporalLow <
    ui_type = "slider"; ui_min = 0.001; ui_max = 0.08; ui_step = 0.001;
    ui_label = "Luma Instability Low";
    ui_category = "C Correction";
> = 0.010;

uniform float LumaTemporalHigh <
    ui_type = "slider"; ui_min = 0.01; ui_max = 0.20; ui_step = 0.005;
    ui_label = "Luma Instability High";
    ui_category = "C Correction";
> = 0.070;

uniform float EdgeSharpness <
    ui_type = "slider"; ui_min = 1.0; ui_max = 20.0; ui_step = 0.5;
    ui_label = "Edge-aware Detail Support";
    ui_category = "C Correction";
> = 8.0;

uniform float ChromaSuppression <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Chroma Suppression";
    ui_category = "C Correction";
> = 1.00;

uniform float LumaSuppression <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Luma Detail Suppression";
    ui_category = "C Correction";
> = 1.00;

uniform float FireflySuppression <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Isolated Outlier Repair";
    ui_category = "C Correction";
> = 1.00;

uniform float MotionBleedStrength <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.40; ui_step = 0.01;
    ui_label = "Motion-conditioned Directional Bleed";
    ui_category = "Pseudo-Flow & Directional Bleed";
    ui_tooltip = "Adds a short trailing bleed from current-frame neighbors only; no old RGB is accumulated.";
> = 0.16;

uniform float MotionReleaseFrames <
    ui_type = "slider"; ui_min = 1.0; ui_max = 8.0; ui_step = 1.0;
    ui_label = "Motion Protection Release (frames)";
    ui_category = "Pseudo-Flow & Directional Bleed";
    ui_tooltip = "Approximate e-folding time in frames. A disappearance resets confidence memory immediately.";
> = 3.0;

uniform float DepthBoundaryGuard <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Depth Boundary Guard";
    ui_category = "Depth Awareness";
    ui_tooltip = "Reduces neighbor correction/bleed across depth discontinuities. Set 0 to disable.";
> = 1.0;

uniform float DepthMotionValidation <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Depth Motion Validation";
    ui_category = "Depth Awareness";
    ui_tooltip = "Down-weights pseudo-flow when current depth disagrees with the previous matched depth. Set 0 to disable.";
> = 0.65;

uniform float DepthBoundaryThreshold <
    ui_type = "slider"; ui_min = 0.005; ui_max = 0.30; ui_step = 0.005;
    ui_label = "Depth Boundary Sensitivity";
    ui_category = "Depth Awareness";
    ui_tooltip = "Lower values guard subtler depth discontinuities; raise if camera motion over-rejects matches.";
> = 0.08;

uniform float DepthMotionThreshold <
    ui_type = "slider"; ui_min = 0.005; ui_max = 0.30; ui_step = 0.005;
    ui_label = "Depth Match Tolerance";
    ui_category = "Depth Awareness";
    ui_tooltip = "Tolerance for depth changes between current pixels and their previous-frame match.";
> = 0.09;

// ---- Sampling / color helpers ------------------------------------------------
float3 GetColor(float2 uv)
{
    // This technique writes to the screen only after Grid and correction work,
    // so this is still the unmodified input image at every GetColor call.
    return tex2D(ReShade::BackBuffer, uv).rgb;
}

float GetLuma(float3 col)
{
    // Keep the original detector's luma weights exactly.
    return dot(col, float3(0.299, 0.587, 0.114));
}

float3 RGBToYCoCg(float3 c)
{
    return float3(
        0.25 * c.r + 0.50 * c.g + 0.25 * c.b,
        0.50 * c.r - 0.50 * c.b,
       -0.25 * c.r + 0.50 * c.g - 0.25 * c.b
    );
}

float3 YCoCgToRGB(float3 c)
{
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

float ChannelDifferenceYCoCg(float3 a, float3 b)
{
    return 0.5 * (abs(a.y - b.y) + abs(a.z - b.z));
}

// Stamp history with a modulo-2048 frame index. RGBA16F represents these
// integer values exactly; the negative encoding distinguishes valid stamps from
// initially cleared textures (alpha == 0). If history age is ambiguous, fail closed.
float CurrentFrameStamp()
{
    return FrameCount - 2048.0 * floor(FrameCount / 2048.0);
}

float HistoryFrameAge(float storedStamp)
{
    if (storedStamp >= -0.5) return 4096.0; // not initialized / invalid
    float oldFrame = -storedStamp - 1.0;
    float age = CurrentFrameStamp() - oldFrame;
    if (age < 0.0) age += 2048.0;
    return age;
}

float GetSignatureDifference(float4 currentSig, float4 previousSig)
{
    // Unchanged v0.1 compact temporal signature.
    float3 currentPhases = currentSig.gba;
    float3 previousPhases = previousSig.gba;
    float phaseDiff = (
        abs(currentPhases.r - previousPhases.r) +
        abs(currentPhases.g - previousPhases.g) +
        abs(currentPhases.b - previousPhases.b)
    ) * (1.0 / 3.0);
    float gridDiff = abs(currentSig.r - previousSig.r) * 0.50;
    return saturate(max(phaseDiff, gridDiff));
}

// Compact YCoCg-aware difference for motion validation. Luma dominates;
// chroma contributes enough to distinguish colored lines without overreacting
// to small hue shifts.
float ColorPixelDistance(float3 a, float3 b)
{
    float3 ya = RGBToYCoCg(a);
    float3 yb = RGBToYCoCg(b);
    return saturate(abs(ya.x - yb.x) + 0.35 * ChannelDifferenceYCoCg(ya, yb));
}

// ReShade's configured depth orientation/linearization is applied here.
float GetDepthValue(float2 uv)
{
    return saturate(ReShade::GetLinearizedDepth(uv));
}

// Dimensionless relative separation. The floor prevents tiny near-range values
// from exploding the ratio; it is not a world-space distance estimate.
float DepthSeparation(float a, float b)
{
    return abs(a - b) / (0.025 + max(max(a, b), 0.0));
}

float DepthBoundaryMask(float a, float b)
{
    float low = max(DepthBoundaryThreshold, 0.001);
    float high = low + max(0.02, low * 0.75);
    return smoothstep(low, high, DepthSeparation(a, b));
}

float DepthMatchTrust(float currentDepth, float previousDepth)
{
    float low = max(DepthMotionThreshold, 0.001);
    float high = low + max(0.025, low * 0.80);
    return 1.0 - smoothstep(low, high, DepthSeparation(currentDepth, previousDepth));
}

float DepthNeighborCompatibility(float centerDepth, float neighborDepth)
{
    return lerp(1.0, 1.0 - DepthBoundaryMask(centerDepth, neighborDepth), saturate(DepthBoundaryGuard));
}


float4 BuildGridSignature(float2 uv)
{
    float2 ts = BUFFER_RCP_SIZE;
    float3 center = GetColor(uv);
    float3 r1 = GetColor(uv + float2( 1.0,  0.0) * ts);
    float3 l1 = GetColor(uv + float2(-1.0,  0.0) * ts);
    float3 u1 = GetColor(uv + float2( 0.0,  1.0) * ts);
    float3 d1 = GetColor(uv + float2( 0.0, -1.0) * ts);
    float3 r2 = GetColor(uv + float2( 2.0,  0.0) * ts);
    float3 l2 = GetColor(uv + float2(-2.0,  0.0) * ts);
    float3 u2 = GetColor(uv + float2( 0.0,  2.0) * ts);
    float3 d2 = GetColor(uv + float2( 0.0, -2.0) * ts);
    float3 tr = GetColor(uv + float2( 1.0,  1.0) * ts);
    float3 tl = GetColor(uv + float2(-1.0,  1.0) * ts);
    float3 br = GetColor(uv + float2( 1.0, -1.0) * ts);
    float3 bl = GetColor(uv + float2(-1.0, -1.0) * ts);

    float3 phaseA = (center + r2 + l2 + u2 + d2) * 0.20;
    float3 phaseB = (r1 + l1 + u1 + d1) * 0.25;
    float3 phaseC = (tr + tl + br + bl) * 0.25;
    float3 phaseAB = phaseA - phaseB;
    float3 phaseAC = phaseA - phaseC;
    float3 phaseBC = phaseB - phaseC;
    float variance = (
        dot(phaseAB, phaseAB) +
        dot(phaseAC, phaseAC) +
        dot(phaseBC, phaseBC)
    ) * (1.0 / 6.0);
    float spatialGrid = saturate(sqrt(max(variance, 0.0)) * GridSensitivity);
    return float4(spatialGrid, GetLuma(phaseA), GetLuma(phaseB), GetLuma(phaseC));
}

// ---- Pass 1: raw frame capture ----------------------------------------------
float4 PS_CaptureCurrentColor(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(ReShade::BackBuffer, uv);
}

// ---- Pass 2: exact v0.1 spatial Grid signature -------------------------------
float4 PS_GridSignature(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return BuildGridSignature(uv);
}

// ---- Pass 3: exact v0.1 temporal signature match -----------------------------
float4 PS_GridTemporal(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 currentSig = tex2D(CurrentGridSampler, uv);
    float previousColorStamp = tex2D(PreviousColorSampler, uv).a;
    if (abs(HistoryFrameAge(previousColorStamp) - 1.0) > 0.1)
        return float4(0.0, 0.0, 0.0, 0.0);

    float2 ts = BUFFER_RCP_SIZE;
    float bestScore = 1e6;
    float bestRawDiff = 1.0;
    float centerDiff = 1.0;
    float2 bestOffsetPx = float2(0.0, 0.0);
    float bestXScore = 1e6;
    float bestXDiff = 1.0;
    float bestYScore = 1e6;
    float bestYDiff = 1.0;
    float xOffset = 0.0;
    float yOffset = 0.0;

    // Keep the original 3x3 match for the frozen C temporal residual, but also
    // record independent horizontal and vertical evidence from the cardinal cross.
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            float2 offsetPx = float2((float)x, (float)y);
            float4 previousSig = tex2D(PreviousGridSampler, uv + offsetPx * ts);
            float rawDiff = GetSignatureDifference(currentSig, previousSig);
            float score = rawDiff + length(offsetPx) * LocalShiftPenalty;
            if (x == 0 && y == 0) centerDiff = rawDiff;
            if (score < bestScore)
            {
                bestScore = score;
                bestRawDiff = rawDiff;
                bestOffsetPx = offsetPx;
            }
            if (y == 0 && x != 0 && score < bestXScore)
            {
                bestXScore = score;
                bestXDiff = rawDiff;
                xOffset = (float)x;
            }
            if (x == 0 && y != 0 && score < bestYScore)
            {
                bestYScore = score;
                bestYDiff = rawDiff;
                yOffset = (float)y;
            }
        }
    }

    float highThreshold = max(TemporalThresholdHigh, TemporalThresholdLow + 0.001);
    float temporalResidual = smoothstep(TemporalThresholdLow, highThreshold, bestRawDiff);

    // Pseudo-flow triangulation: independently require horizontal and/or vertical
    // evidence. A diagonal is accepted only when the combined diagonal signature
    // confirms both cardinal hypotheses; otherwise retain the stronger axis only.
    float xImprovement = max(0.0, centerDiff - bestXScore);
    float yImprovement = max(0.0, centerDiff - bestYScore);
    float xConfidence = smoothstep(0.010, 0.070, xImprovement);
    float yConfidence = smoothstep(0.010, 0.070, yImprovement);
    float xValid = step(0.20, xConfidence);
    float yValid = step(0.20, yConfidence);
    float2 chosenOffsetPx = float2(0.0, 0.0);
    float directionalSupport = 0.0;
    float chosenSignatureDiff = centerDiff;

    if (xValid > 0.5 && yValid > 0.5)
    {
        float2 diagonalOffset = float2(xOffset, yOffset);
        float4 diagonalSig = tex2D(PreviousGridSampler, uv + diagonalOffset * ts);
        float diagonalDiff = GetSignatureDifference(currentSig, diagonalSig);
        float diagonalScore = diagonalDiff + length(diagonalOffset) * LocalShiftPenalty;
        float diagonalImprovement = centerDiff - diagonalScore;
        float diagonalConfidence = smoothstep(0.014, 0.080, diagonalImprovement);
        // Avoid combining two individually weak shifts into a false diagonal.
        if (diagonalConfidence > 0.18 && diagonalDiff <= min(bestXDiff, bestYDiff) + 0.025)
        {
            chosenOffsetPx = diagonalOffset;
            chosenSignatureDiff = diagonalDiff;
            directionalSupport = min(xConfidence, yConfidence) * diagonalConfidence;
        }
        else if (xImprovement >= yImprovement)
        {
            chosenOffsetPx = float2(xOffset, 0.0);
            chosenSignatureDiff = bestXDiff;
            directionalSupport = xConfidence;
        }
        else
        {
            chosenOffsetPx = float2(0.0, yOffset);
            chosenSignatureDiff = bestYDiff;
            directionalSupport = yConfidence;
        }
    }
    else if (xValid > 0.5)
    {
        chosenOffsetPx = float2(xOffset, 0.0);
        chosenSignatureDiff = bestXDiff;
        directionalSupport = xConfidence;
    }
    else if (yValid > 0.5)
    {
        chosenOffsetPx = float2(0.0, yOffset);
        chosenSignatureDiff = bestYDiff;
        directionalSupport = yConfidence;
    }

    // Raw current/previous RGB only validates the pseudo-vector. It never becomes
    // an output color source; directional bleed below samples only current RGB.
    float3 currentCenterRgb = tex2D(CurrentColorSampler, uv).rgb;
    float3 previousCenterRgb = tex2D(PreviousColorSampler, uv).rgb;
    float3 previousMatchedRgb = tex2D(PreviousColorSampler, uv + chosenOffsetPx * ts).rgb;
    float previousCenterDistance = ColorPixelDistance(currentCenterRgb, previousCenterRgb);
    float matchedColorDistance = ColorPixelDistance(currentCenterRgb, previousMatchedRgb);

    float matchQuality = 1.0 - smoothstep(0.020, 0.16, matchedColorDistance);
    float shiftConfidence = smoothstep(0.012, 0.085, previousCenterDistance - matchedColorDistance);
    float transitionSignal = smoothstep(0.020, 0.22, previousCenterDistance);
    float gridRisk = saturate(currentSig.r * 1.8);
    float signatureQuality = 1.0 - smoothstep(TemporalThresholdLow, highThreshold, chosenSignatureDiff);
    float displacement = length(chosenOffsetPx);
    float rawMotionConfidence = 0.0;
    if (displacement > 0.25 && directionalSupport > 0.0)
    {
        rawMotionConfidence = saturate(
            gridRisk * matchQuality * shiftConfidence * transitionSignal *
            signatureQuality * directionalSupport);
    }

    // Validate the pseudo-vector against depth at the previous-frame matched
    // location. This is a soft gate: camera/object depth changes can be real.
    float currentDepth = GetDepthValue(uv);
    float previousMatchedDepth = tex2D(PreviousDepthSampler, uv + chosenOffsetPx * ts).r;
    float depthMatchTrust = DepthMatchTrust(currentDepth, previousMatchedDepth);
    rawMotionConfidence *= lerp(1.0, depthMatchTrust, saturate(DepthMotionValidation));

    // Store confidence/vector only. If the structure vanishes at this pixel,
    // continuity falls to zero immediately; old RGB is never retained.
    float4 previousMotion = tex2D(PreviousMotionSampler, uv);
    float continuity = 1.0 - smoothstep(0.018, 0.11, previousCenterDistance);
    float releaseFactor = exp(-1.0 / max(MotionReleaseFrames, 1.0));
    float2 releasedMatchUv = uv - previousMotion.gb * ts;
    float previousReleasedDepth = tex2D(PreviousDepthSampler, releasedMatchUv).r;
    float releasedDepthTrust = DepthMatchTrust(currentDepth, previousReleasedDepth);
    float releasedConfidence = previousMotion.a * releaseFactor * continuity *
        lerp(1.0, releasedDepthTrust, saturate(DepthMotionValidation));
    float motionConfidence = max(rawMotionConfidence, releasedConfidence);

    float2 motionVector = float2(0.0, 0.0);
    if (rawMotionConfidence > releasedConfidence && rawMotionConfidence > 0.001)
        motionVector = -chosenOffsetPx;
    else if (releasedConfidence > 0.001)
        motionVector = previousMotion.gb;

    // R preserves v0.4's original temporal residual; G/B are pseudo velocity in
    // px/frame from cardinal triangulation; A is confidence/release memory.
    return float4(temporalResidual, motionVector.x, motionVector.y, motionConfidence);
}

// ---- Pass 4: fixed C-only selective channel-wise correction ----------------
float4 PS_GGTDSOutput(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 original = GetColor(uv);
    float4 gridSig = tex2D(CurrentGridSampler, uv);
    float4 temporal = tex2D(GridTemporalSampler, uv);
    float spatialGrid = saturate(gridSig.r);
    float temporalRisk = saturate(temporal.r);
    float combinedRisk = saturate(spatialGrid * temporalRisk); // unchanged diagnostic

    float2 ts = BUFFER_RCP_SIZE;
    float3 c = RGBToYCoCg(original);
    float4 previousColorSample = tex2D(PreviousColorSampler, uv);
    float4 olderColorSample = tex2D(OlderColorSampler, uv);
    float3 p = RGBToYCoCg(previousColorSample.rgb);
    float3 q = RGBToYCoCg(olderColorSample.rgb);
    float previousAge = HistoryFrameAge(previousColorSample.a);
    float olderAge = HistoryFrameAge(olderColorSample.a);
    float historyValid = (abs(previousAge - 1.0) <= 0.1 && abs(olderAge - 2.0) <= 0.1) ? 1.0 : 0.0;

    float instabilityY = 0.0;
    float instabilityC = 0.0;
    float phaseFlipSignalY = 0.0;
    float phaseFlipSignalC = 0.0;
    float outlierY = 0.0;
    float outlierC = 0.0;

    if (historyValid > 0.5)
    {
        float dY1 = abs(c.x - p.x);
        float dY2 = abs(c.x - q.x);
        float dYPQ = abs(p.x - q.x);
        float dC1 = ChannelDifferenceYCoCg(c, p);
        float dC2 = ChannelDifferenceYCoCg(c, q);
        float dCPQ = ChannelDifferenceYCoCg(p, q);

        float yNow = smoothstep(LumaTemporalLow, max(LumaTemporalHigh, LumaTemporalLow + 0.001), dY1);
        float yOld = smoothstep(LumaTemporalLow, max(LumaTemporalHigh, LumaTemporalLow + 0.001), dY2);
        float yPair = smoothstep(LumaTemporalLow, max(LumaTemporalHigh, LumaTemporalLow + 0.001), dYPQ);
        float cNow = smoothstep(ChromaTemporalLow, max(ChromaTemporalHigh, ChromaTemporalLow + 0.001), dC1);
        float cOld = smoothstep(ChromaTemporalLow, max(ChromaTemporalHigh, ChromaTemporalLow + 0.001), dC2);
        float cPair = smoothstep(ChromaTemporalLow, max(ChromaTemporalHigh, ChromaTemporalLow + 0.001), dCPQ);

        // A/B/A (or B/A/B): current agrees with t-2 but differs from t-1.
        phaseFlipSignalY = yNow * (1.0 - yOld);
        phaseFlipSignalC = cNow * (1.0 - cOld);

        // One-frame outlier: current differs from both histories, while the
        // previous pair agrees. Spatial isolation is applied below.
        outlierY = yNow * yOld * (1.0 - yPair);
        outlierC = cNow * cOld * (1.0 - cPair);

        // General temporal evidence is accepted only when that component moves
        // and the two-frame pair is not already indicating continuous change.
        instabilityY = max(phaseFlipSignalY, temporalRisk * yNow * (1.0 - 0.65 * yPair));
        instabilityC = max(phaseFlipSignalC, temporalRisk * cNow * (1.0 - 0.65 * cPair));
    }

    // Eight-neighbour robust statistics, used only for isolated-outlier gating.
    float3 nLrgb  = GetColor(uv + float2(-1.0,  0.0) * ts);
    float3 nRrgb  = GetColor(uv + float2( 1.0,  0.0) * ts);
    float3 nUrgb  = GetColor(uv + float2( 0.0, -1.0) * ts);
    float3 nDrgb  = GetColor(uv + float2( 0.0,  1.0) * ts);
    float3 nL = RGBToYCoCg(nLrgb);  float3 nR = RGBToYCoCg(nRrgb);
    float3 nU = RGBToYCoCg(nUrgb);  float3 nD = RGBToYCoCg(nDrgb);

    float depthCenter = GetDepthValue(uv);
    float depthL = GetDepthValue(uv + float2(-1.0,  0.0) * ts);
    float depthR = GetDepthValue(uv + float2( 1.0,  0.0) * ts);
    float depthU = GetDepthValue(uv + float2( 0.0, -1.0) * ts);
    float depthD = GetDepthValue(uv + float2( 0.0,  1.0) * ts);
    float depthEdgeL = DepthBoundaryMask(depthCenter, depthL);
    float depthEdgeR = DepthBoundaryMask(depthCenter, depthR);
    float depthEdgeU = DepthBoundaryMask(depthCenter, depthU);
    float depthEdgeD = DepthBoundaryMask(depthCenter, depthD);
    float depthKeepL = DepthNeighborCompatibility(depthCenter, depthL);
    float depthKeepR = DepthNeighborCompatibility(depthCenter, depthR);
    float depthKeepU = DepthNeighborCompatibility(depthCenter, depthU);
    float depthKeepD = DepthNeighborCompatibility(depthCenter, depthD);
    float depthBoundaryDebug = max(max(depthEdgeL, depthEdgeR), max(depthEdgeU, depthEdgeD));

    // Replace cross-surface neighbours with the center for isolated-outlier
    // statistics. This prevents a foreground/background edge from pretending
    // that the center is an isolated firefly solely due to depth discontinuity.
    float3 nLStats = lerp(c, nL, depthKeepL);
    float3 nRStats = lerp(c, nR, depthKeepR);
    float3 nUStats = lerp(c, nU, depthKeepU);
    float3 nDStats = lerp(c, nD, depthKeepD);

    // Temporal activity in the four cardinal neighbours: a true one-pixel
    // transient can occur on a wire/texture edge, where spatial flatness alone
    // is the wrong test. Stable neighbours make isolated history disagreement
    // more credible; coherent moving regions lose this isolation confidence.
    float outlierMaskY = 0.0;
    float outlierMaskC = 0.0;
    float3 pL = p; float3 pR = p; float3 pU = p; float3 pD = p;
    // C-only baseline: reuse cardinal history taps for outlier confidence.
    {
        pL = RGBToYCoCg(tex2D(PreviousColorSampler, uv + float2(-1.0,  0.0) * ts).rgb);
        pR = RGBToYCoCg(tex2D(PreviousColorSampler, uv + float2( 1.0,  0.0) * ts).rgb);
        pU = RGBToYCoCg(tex2D(PreviousColorSampler, uv + float2( 0.0, -1.0) * ts).rgb);
        pD = RGBToYCoCg(tex2D(PreviousColorSampler, uv + float2( 0.0,  1.0) * ts).rgb);
        float neighbourActivityY = 0.25 * (abs(nL.x-pL.x) + abs(nR.x-pR.x) + abs(nU.x-pU.x) + abs(nD.x-pD.x));
        float neighbourActivityC = 0.25 * (ChannelDifferenceYCoCg(nL,pL) + ChannelDifferenceYCoCg(nR,pR) + ChannelDifferenceYCoCg(nU,pU) + ChannelDifferenceYCoCg(nD,pD));
        float temporalIsolationY = 1.0 - smoothstep(LumaTemporalLow, max(LumaTemporalHigh, LumaTemporalLow+0.001), neighbourActivityY);
        float temporalIsolationC = 1.0 - smoothstep(ChromaTemporalLow, max(ChromaTemporalHigh, ChromaTemporalLow+0.001), neighbourActivityC);

        float3 neighbourMean = (nLStats + nRStats + nUStats + nDStats) * 0.25;
        float nYMin = min(min(nLStats.x, nRStats.x), min(nUStats.x, nDStats.x));
        float nYMax = max(max(nLStats.x, nRStats.x), max(nUStats.x, nDStats.x));
        float nCoMin = min(min(nLStats.y, nRStats.y), min(nUStats.y, nDStats.y));
        float nCoMax = max(max(nLStats.y, nRStats.y), max(nUStats.y, nDStats.y));
        float nCgMin = min(min(nLStats.z, nRStats.z), min(nUStats.z, nDStats.z));
        float nCgMax = max(max(nLStats.z, nRStats.z), max(nUStats.z, nDStats.z));
        float nYRange = nYMax - nYMin;
        float nCRange = max(nCoMax - nCoMin, nCgMax - nCgMin);
        float yNeighbourCoherence = 1.0 - smoothstep(0.025, 0.16, nYRange);
        float cNeighbourCoherence = 1.0 - smoothstep(0.018, 0.13, nCRange);
        float spatialOutlierY = smoothstep(0.025, 0.18, abs(c.x - neighbourMean.x)) * yNeighbourCoherence;
        float spatialOutlierC = smoothstep(0.018, 0.11, ChannelDifferenceYCoCg(c, neighbourMean)) * cNeighbourCoherence;
        outlierMaskY = saturate(outlierY * max(spatialOutlierY, 0.90 * temporalIsolationY));
        outlierMaskC = saturate(outlierC * max(spatialOutlierC, 0.90 * temporalIsolationC));
    }

    // Edge-aware cardinal estimate. We filter only the residual from this local
    // estimate, and only where Grid + component-specific temporal evidence agree.
    float3 rgbL = nL; float3 rgbR = nR; float3 rgbU = nU; float3 rgbD = nD;
    float wL = depthKeepL / (1.0 + EdgeSharpness * (abs(rgbL.x-c.x) + 0.70*ChannelDifferenceYCoCg(rgbL,c)));
    float wR = depthKeepR / (1.0 + EdgeSharpness * (abs(rgbR.x-c.x) + 0.70*ChannelDifferenceYCoCg(rgbR,c)));
    float wU = depthKeepU / (1.0 + EdgeSharpness * (abs(rgbU.x-c.x) + 0.70*ChannelDifferenceYCoCg(rgbU,c)));
    float wD = depthKeepD / (1.0 + EdgeSharpness * (abs(rgbD.x-c.x) + 0.70*ChannelDifferenceYCoCg(rgbD,c)));
    float wSumRaw = wL+wR+wU+wD;
    float wSum = max(wSumRaw, 0.001);
    float3 edgeWeightedSum = rgbL*wL + rgbR*wR + rgbU*wU + rgbD*wD;
    // If every neighbor crosses a depth discontinuity, fall back to the source
    // pixel rather than accidentally treating a zero-weight estimate as black.
    float3 edgeBase = (edgeWeightedSum + c * max(0.001 - wSumRaw, 0.0)) / wSum;
    float detailSupport = saturate((wSum - 0.45) / 1.75);

    float gateY = saturate(spatialGrid * instabilityY);
    float gateC = saturate(spatialGrid * instabilityC);
    // Known A/B/A alternation may relax the spatial support penalty: the
    // detail is temporally unstable even where a strong current-frame edge exists.
    float supportY = max(detailSupport, 0.90 * phaseFlipSignalY);
    float supportC = max(detailSupport, 0.90 * phaseFlipSignalC);
    float appliedY = gateY * LumaSuppression * supportY;
    float appliedC = gateC * ChromaSuppression * supportC;
    float3 corrected = c;
    corrected.yz = lerp(c.yz, edgeBase.yz, appliedC);
    corrected.x = lerp(c.x, edgeBase.x, appliedY);

    float fireflyYGate = spatialGrid * outlierMaskY * FireflySuppression;
    float fireflyCGate = spatialGrid * outlierMaskC * FireflySuppression;
    // Reuse history only under the explicit isolated-outlier test.
    float3 historyConsensus = 0.5 * (p + q);
    corrected.x = lerp(corrected.x, historyConsensus.x, fireflyYGate);
    corrected.yz = lerp(corrected.yz, historyConsensus.yz, fireflyCGate);

    float3 outputRgb = YCoCgToRGB(corrected);

    // One-pixel directional bleed is sourced exclusively from CURRENT raw RGB.
    // It is driven by the source neighbor's signed motion and confidence, so a
    // vanished source cannot leave an outgoing old-color tail. Trailing-side
    // weighting approximates a short shutter without blending old frames.
    float3 bleedColorSum = float3(0.0, 0.0, 0.0);
    float bleedWeightSum = 0.0;

    float2 offL = float2(-1.0, 0.0);
    float2 offR = float2( 1.0, 0.0);
    float2 offU = float2(0.0,-1.0);
    float2 offD = float2(0.0, 1.0);

    float4 mL = tex2D(GridTemporalSampler, uv + offL * ts);
    float4 mR = tex2D(GridTemporalSampler, uv + offR * ts);
    float4 mU = tex2D(GridTemporalSampler, uv + offU * ts);
    float4 mD = tex2D(GridTemporalSampler, uv + offD * ts);

    float vLenL = max(length(mL.gb), 0.001);
    float vLenR = max(length(mR.gb), 0.001);
    float vLenU = max(length(mU.gb), 0.001);
    float vLenD = max(length(mD.gb), 0.001);
    float mwL = mL.a * saturate(-dot(mL.gb / vLenL, -offL)) * depthKeepL;
    float mwR = mR.a * saturate(-dot(mR.gb / vLenR, -offR)) * depthKeepR;
    float mwU = mU.a * saturate(-dot(mU.gb / vLenU, -offU)) * depthKeepU;
    float mwD = mD.a * saturate(-dot(mD.gb / vLenD, -offD)) * depthKeepD;

    bleedColorSum += tex2D(CurrentColorSampler, uv + offL * ts).rgb * mwL;
    bleedColorSum += tex2D(CurrentColorSampler, uv + offR * ts).rgb * mwR;
    bleedColorSum += tex2D(CurrentColorSampler, uv + offU * ts).rgb * mwU;
    bleedColorSum += tex2D(CurrentColorSampler, uv + offD * ts).rgb * mwD;
    bleedWeightSum = mwL + mwR + mwU + mwD;
    float3 bleedColor = bleedColorSum / max(bleedWeightSum, 0.001);
    float bleedAmount = min(0.28, MotionBleedStrength * saturate(bleedWeightSum));
    outputRgb = lerp(outputRgb, bleedColor, bleedAmount);
    float3 outputDelta = abs(outputRgb - original);

    // Diagnostic views: R remains the original temporal residual;
    // G/B show signed motion vector, A shows confidence/release memory.
    if (DebugView == 0) return float4(original, 1.0);
    if (DebugView == 1) return float4(spatialGrid.xxx, 1.0);
    if (DebugView == 2) return float4(temporalRisk.xxx, 1.0);
    if (DebugView == 3) return float4(combinedRisk.xxx, 1.0);
    if (DebugView == 4) return float4(saturate(float3(spatialGrid, temporalRisk, combinedRisk)), 1.0);
    if (DebugView == 5) return float4(saturate(float3(0.5 + 0.5 * temporal.g, 0.5 + 0.5 * temporal.b, temporal.a)), 1.0);
    if (DebugView == 6) return float4(temporal.a.xxx, 1.0);
    if (DebugView == 7) return float4(saturate(float3(appliedC, appliedC, appliedC)), 1.0);
    if (DebugView == 8) return float4(saturate(float3(appliedY, appliedY, appliedY)), 1.0);
    if (DebugView == 9) return float4(saturate(float3(max(outlierMaskY, outlierMaskC), 0.0, 0.0)), 1.0);
    if (DebugView == 10) return float4(saturate(float3(instabilityY, instabilityC, outlierMaskY+outlierMaskC)), 1.0);
    if (DebugView == 11) return float4(saturate(outputDelta * 4.0), 1.0);
    if (DebugView == 12) return float4(outputRgb, 1.0);
    if (DebugView == 13) return float4(depthCenter.xxx, 1.0);
    if (DebugView == 14) return float4(depthBoundaryDebug.xxx, 1.0);
    if (DebugView == 15)
    {
        float2 matchUv = uv - temporal.gb * ts;
        float previousDepthMatch = tex2D(PreviousDepthSampler, matchUv).r;
        float depthTrustDebug = DepthMatchTrust(depthCenter, previousDepthMatch);
        return float4(depthTrustDebug.xxx, 1.0);
    }
    return float4(outputRgb, 1.0);
}

// ---- History rotation. Older <- previous must happen before previous <- now. -
float4 PS_PersistOlderColor(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(PreviousColorSampler, uv);
}
float4 PS_PersistPreviousColor(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 currentRgb = tex2D(CurrentColorSampler, uv).rgb;
    float encodedFrameStamp = -(CurrentFrameStamp() + 1.0);
    return float4(currentRgb, encodedFrameStamp);
}
float4 PS_PersistPreviousGrid(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(CurrentGridSampler, uv);
}
float4 PS_PersistPreviousMotion(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2D(GridTemporalSampler, uv);
}
float4 PS_PersistPreviousDepth(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return float4(GetDepthValue(uv), 0.0, 0.0, 1.0);
}

technique DASR_Core < ui_tooltip = "DASR-Core v0.7.1; descriptive debug menu and grouped controls"; >
{
    pass CaptureCurrentColor
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CaptureCurrentColor;
        RenderTarget = CurrentColorBuffer;
    }
    pass GridSignaturePass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GridSignature;
        RenderTarget = CurrentGridBuffer;
    }
    pass GridTemporalAnalysisPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GridTemporal;
        RenderTarget = GridTemporalBuffer;
    }
    pass GGTDSCorrectionPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GGTDSOutput;
    }
    pass PersistOlderColorPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_PersistOlderColor;
        RenderTarget = OlderColorBuffer;
    }
    pass PersistPreviousColorPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_PersistPreviousColor;
        RenderTarget = PreviousColorBuffer;
    }
    pass PersistPreviousGridPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_PersistPreviousGrid;
        RenderTarget = PreviousGridBuffer;
    }
    pass PersistPreviousMotionPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_PersistPreviousMotion;
        RenderTarget = PreviousMotionBuffer;
    }
    pass PersistPreviousDepthPass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_PersistPreviousDepth;
        RenderTarget = PreviousDepthBuffer;
    }
}
