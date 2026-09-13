# Table of Contents

1. [Introduction](#1-introduction)
2. [What DASR Does](#2-what-dasr-does)
3. [How DASR Works](#3-how-dasr-works)
4. [Performance Considerations and Shader Cost](#4-performance-considerations-and-shader-cost)
5. [Known Limitations](#5-known-limitations)
6. [Recommended Settings and Tuning Philosophy](#6-recommended-settings-and-tuning-philosophy)
7. [Requirements & Compatibility](#7-requirements--compatibility)

 ---

# 1. Introduction

Modern high-end rendering pipelines have access to increasingly sophisticated solutions for image reconstruction and temporal stability. Techniques such as advanced temporal reconstruction, machine learning upscalers and vendor-specific solutions can greatly improve image quality when properly integrated into the rendering pipeline.

However, not every engine has access to these technologies. Many simulation-focused and long-lived engines are built around more traditional rendering architectures, where development resources are focused on simulation accuracy, content systems and performance rather than cutting-edge image reconstruction.

As a result, even with traditional anti-aliasing methods such as MSAA 8x or high-resolution supersampling, certain types of temporal instability can remain extremely visible: distant thin geometry, fences, vegetation, rails, small structures and high-frequency details may continuously flicker, appear and disappear, or change brightness as the camera moves.

This is not always a matter of insufficient rendering resolution. Some artifacts are caused by the interaction between the scene frequency and the sampling pattern itself. When a detail becomes smaller than the pixel footprint, increasing resolution or applying stronger smoothing may reduce the problem, but it cannot always guarantee temporal stability.

DASR was created to address this specific scenario: providing a lightweight post-process approach for environments where full temporal reconstruction solutions are unavailable or impractical.

---

# 2. What DASR does

DASR is built around a multi-stage analysis and stabilization pipeline.
Instead of applying a uniform blur or relying only on temporal history, it evaluates the rendered image through multiple complementary signals. Each detector contributes information about the probability that a pixel or region is affected by temporal instability.
The complete pipeline follows three main stages:
**Detect - Predict - Stabilize**

## 2a. Detect - Local instability analysis
The first stage builds a risk map by analyzing the current frame.
DASR combines several detectors:

**Grid / Brick Divergence Detector*
The primary detection method.
Multiple local sampling patterns with different spatial phases are compared to estimate how sensitive a region is to sampling position. When different sampling arrangements produce significantly different results, the area is considered unstable and more likely to produce aliasing or shimmer.

**Periodicity Detector**
Analyzes repeating local structures that are commonly associated with temporal artifacts.
Regular patterns such as thin fences, vegetation clusters, rails, wires or distant geometry can generate unstable pixel responses. The periodicity analysis helps identify these cases.

**Temporal Instability Analysis**
Compares the current frame against previous information stored in history.
A small local search is used to compensate for minor movement and reduce false positives caused by camera motion. Temporal variation is then combined with structural instability rather than being treated as a standalone signal.

**Depth Awareness**
Uses the depth buffer to weight the response depending on scene distance.
This allows the shader to prioritize areas where subpixel instability is more likely to appear while avoiding unnecessary processing where it provides little benefit.
You will need to properly configure depth buffer in reshade.

## 2b. Predict - Risk evaluation
The detected signals are combined into a unified risk map.
Instead of deciding only from the current pixel value, DASR evaluates whether a region is likely to become unstable during motion.
The risk map stores multiple information channels:
* **Red channel:** overall shimmer risk
* **Green channel:** alias confidence used by the filtering stage
* **Blue channel:** periodic structure confidence
* **Alpha channel:** temporal alias history
This separation allows the stabilization stage to react differently depending on the type and intensity of instability detected.

## 2c. Stabilize - Adaptive anisotropic filtering
The final stage applies a directional low-pass filter only where needed.
DASR uses local structure analysis to determine the dominant orientation of the image features. The filter is then applied perpendicular to the detected structure, reducing unstable high-frequency variations while preserving edges.
The filtering strength adapts dynamically:
* Low risk : minimal intervention
* Medium risk : limited filtering
* High risk : stronger stabilization

The stabilization stage is composed of multiple complementary passes rather than a single filter. An adaptive anisotropic spatial filter first removes high-frequency instability while preserving local structure. A subsequent phase-aware stabilization stage analyzes short temporal sequences to suppress alternating sampling-phase artifacts such as moiré shimmer. Finally, a lightweight temporal history stage provides controlled temporal consistency without relying on full image reconstruction.

---

# 3. How DASR work

## 3a. Grid / Brick Divergence Detector
This is the primary instability sensor used by DASR.
The core idea behind this detector is simple:
**A pixel that changes significantly when observed through different sampling arrangements is likely to be unstable.**
Traditional anti-aliasing methods generally attempt to reconstruct a smoother representation of the image after sampling. DASR instead analyzes the sampling process itself, searching for areas where the current pixel representation is highly sensitive to small spatial changes.
These regions are the typical source of temporal shimmer: distant geometry, thin structures, vegetation, wires, fences and other details that occupy only a fraction of a pixel.

**The sampling phase problem**
A rendered image is not a continuous representation of the scene. It is a collection of discrete samples taken on a pixel grid.
When a high-frequency detail interacts with this grid, the final pixel value can depend heavily on the exact position of the sample.
A small camera movement can therefore cause a small geometric feature to cross different sampling phases:
* one frame captures the feature,
* the next frame misses it,
* another frame captures only part of it.
The result is temporal instability: the detail appears to flicker even though the underlying scene is static.
DASR treats this behavior as a sampling reliability problem.

**Multi-phase local sampling**
Instead of evaluating the pixel using a single neighborhood pattern, DASR creates three different virtual sampling configurations:

**Pattern A — Native grid phase**
The first pattern represents the current raster alignment.
It samples:
* the current pixel
* four pixels at a distance of two pixels in the cardinal directions
This creates a wider cross-shaped observation:
```
      *
      |
* ----+---- *
      |
      *
```
The purpose is to estimate the local signal while preserving the current pixel phase.

**Pattern B — Shifted cardinal phase**
The second pattern shifts the observation by one pixel.
It samples the immediate cardinal neighbors:
```
      *
      |
* ----+---- *
      |
      *
```
Although the shape is similar to Pattern A, the sampling phase is different.
This difference is important: a stable region should produce similar results regardless of this small phase shift.
An unstable region will produce a noticeably different response.

**Pattern C — Diagonal brick phase**
The third pattern samples diagonal neighbors:
```
*       *

    +

*       *
```
This creates a brick-like offset configuration inspired by staggered pixel layouts.
The purpose is to detect structures that are not aligned with horizontal or vertical sampling directions, such as:
* diagonal edges
* thin geometry
* repeating patterns
* moiré-like structures

**Divergence calculation**
After evaluating the three patterns, DASR compares their responses.
The detector does not ask:
"Is this pixel detailed?"
Instead it asks:
"Does this pixel produce different answers depending on how it is sampled?"
The differences between the three virtual samples are combined into a divergence value.
High divergence means:
* the local signal is unstable,
* the area is sensitive to sampling phase,
* temporal shimmer is likely.
Low divergence means:
* the region is spatially stable,
* aggressive filtering is unnecessary.

**Why this approach works**
Many shimmer artifacts are not caused by insufficient resolution alone.
A distant object may still flicker even when rendered at very high resolutions because the problem is not only the number of pixels, but the relationship between:
* scene frequency,
* pixel footprint,
* sampling phase.
By measuring phase sensitivity directly, DASR can identify problematic regions before visible flickering occurs.
This is why the Grid / Brick Divergence Detector acts as the foundation of the entire risk map.

**Role inside DASR**
The detector contributes the largest portion of the final instability estimation.
Default contribution:
* Grid / Brick Divergence: 45%
* Temporal instability: 25%
* Periodicity analysis: 20%
* Depth awareness: 10%
This weighting reflects the main design philosophy of DASR:
**Sampling instability is the cause. Temporal shimmer is the symptom.**


## 3b. Periodicity Detector
This is a secondary analysis module designed to identify repeating local structures that are particularly vulnerable to temporal instability.
Many shimmer artifacts do not come from isolated edges, but from repeated high-frequency patterns:
* fences and railings
* vegetation clusters
* cables and wires
* distant tracks and sleepers
* repetitive architectural details
* fine texture patterns
These structures can produce unstable pixel responses because small camera movements continuously change how the repeating pattern aligns with the pixel grid.
The purpose of the Periodicity Detector is not to classify objects, but to recognize a mathematical property of the image:
A signal that repeats at a small spatial scale is more likely to **become unstable during motion**.

**Why repetitive patterns are problematic**
A single edge is usually predictable.
For example, a large object boundary produces a consistent transition between two regions:
```
████████░░░░░░
```
Even if the camera moves slightly, the edge generally remains coherent.
A repetitive pattern behaves differently:
```
█░█░█░█░█░█░█
```
A tiny subpixel movement can completely change the relationship between the pattern and the pixel grid.
One frame may capture:
```
█░█░█░█
```
while another frame may effectively capture:
```
░█░█░█░
```
The scene has not changed, but the sampled representation has.
This is one of the main causes of temporal shimmer.

**Local frequency analysis**
The detector evaluates local luminance variations at multiple distances.
DASR compares:
* immediate pixel differences
* short-range variations
* wider-range variations
The goal is to determine whether a local structure has a repeating behavior rather than a single isolated transition.
The detector uses directional analysis:
* horizontal periodicity
* vertical periodicity
This allows it to detect patterns that repeat along a dominant axis.

**Persistence estimation**
A strong edge creates a response, but a repeating structure creates a response that persists across multiple sampling distances.
DASR evaluates this persistence by comparing variations at different offsets.
A stable periodic pattern tends to show:
* local contrast changes,
* repeated structure,
* consistency over multiple distances.
Random noise or isolated edges generally do not produce the same behavior.
The detector therefore suppresses unreliable signals and focuses on structures that exhibit repeated spatial organization.

**Response shaping**
Raw periodicity is transformed into a confidence value.
The response is intentionally shaped to avoid excessive filtering:
* weak repetitive structures are ignored,
* medium confidence areas receive moderate attention,
* strong periodic patterns contribute significantly to the final risk estimation.
This prevents DASR from reacting to every small detail in the image.

**Interaction with Grid / Brick Divergence**
The Periodicity Detector is not designed to replace the main divergence analysis.
The two systems answer different questions
> Grid / Brick Divergence asks:
> "Does this region change when sampled from different phases?"
> Periodicity Detector asks:
> "Does this region contain a repeating structure that is likely to become unstable?"
When both detectors agree, DASR gains higher confidence that the region contains genuine shimmer risk.
This combination is particularly effective for difficult cases such as distant fences, vegetation and fine repeated geometry.

**Role inside DASR**
The Periodicity Detector contributes to the final risk estimation as a supporting signal:
* Grid / Brick Divergence → primary sampling instability detection
* Temporal Analysis → confirms instability over time
* Periodicity → identifies high-risk repeating structures
* Depth Awareness → adjusts response depending on scene location
Its purpose is not to make the image smoother, but to provide additional context:
Some pixels are dangerous not because they are sharp, but **because they repeat**.


## 3c. Temporal Instability Detector
The Grid-Brick detector is extremely effective at identifying structures that are sensitive to sampling, but not every sensitive structure actually produces visible shimmer.
Some details remain perfectly stable over time even if they have a high spatial frequency.
This is where the temporal detector comes into play.
Instead of simply comparing the current frame with the previous one, DASR performs a small local search inside the history buffer. For every pixel, a 3×3 neighborhood is examined in the previous frame to find the sample that most closely matches the current color.
This approach is intentionally simple but surprisingly robust.
A direct one-to-one frame comparison is very sensitive to camera movement. Even a sub-pixel displacement would incorrectly appear as instability, generating false positives over large portions of the image.

To mitigate this, DASR first estimates a local luminance gradient around the current pixel. The gradient direction is then used as a lightweight motion heuristic, shifting the history lookup approximately one pixel toward the most likely direction of movement before the 3×3 search begins.
This is **not** optical flow and it is **not** motion-vector reconstruction. It is simply a local prediction that compensates for small camera translations while remaining extremely inexpensive to compute.
Once the best historical match has been found, the remaining color difference becomes the temporal instability measure.
However, temporal instability alone is not sufficient to classify shimmer. Any moving object naturally changes between frames, but that does not necessarily mean aliasing is present.

For this reason, the temporal response is multiplied by the Grid-Brick confidence.
In practice, a pixel is considered temporally dangerous only when:
* it belongs to a sampling-sensitive geometric structure;
* it actually changes over time after motion compensation.
This coupling dramatically reduces false positives compared to traditional temporal difference approaches, preventing moving objects from being treated as shimmer unless they also exhibit unstable sampling characteristics.
The resulting temporal confidence is then blended with the other detectors to build the final unified risk map.

The Temporal Instability Detector focuses on measuring whether sampling-sensitive structures actually change over time. It is intentionally conservative and does not directly perform temporal correction. Instead, its output contributes to the global risk estimation, allowing later stages of the pipeline to decide how temporal information should be used.


## 3d. Unified Risk Map
Each detector implemented by DASR measures a different aspect of the aliasing problem.
The Grid-Brick detector evaluates spatial sampling instability.
The temporal detector measures whether that instability actually changes over time.
The periodicity detector identifies repetitive high-frequency structures that are statistically more likely to generate shimmer.
Finally, the depth weighting system allows distant geometry to receive a higher priority, since aliasing becomes increasingly visible as objects shrink on screen.
Individually, none of these detectors is reliable enough to drive filtering decisions.
Each one has situations where it may overreact or completely miss a problematic region.
Rather than relying on a single metric, DASR combines all detector outputs into a unified confidence score.
Each detector contributes through an independent weight:
* Grid-Brick Divergence
* Temporal Instability
* Periodicity
* Depth Weight

The final risk is computed as a normalized weighted average:
```
FinalRisk =
(
    GridBrick  × WGrid +
    Temporal   × WTemporal +
    Periodic   × WPeriodic +
    Depth      × WDepth
)
/
(WGrid + WTemporal + WPeriodic + WDepth)
```

Normalizing by the total weight ensures that the output always remains within a predictable range regardless of the selected configuration.
This design also makes the algorithm highly tunable.
Different rendering engines exhibit different failure modes.
**Some engines mainly suffer from temporal shimmer, others produce strong moiré patterns.**
Some scenes are dominated by distant foliage, while others mainly contain hard geometric edges.
Instead of hardcoding assumptions, DASR exposes the contribution of each detector, allowing the risk map to adapt to the characteristics of the rendering pipeline without modifying the algorithm itself.
The resulting value represents a probability-like confidence that the current pixel is affected by visible aliasing and should therefore receive adaptive filtering in the following stage.

This separation between **detection** and **correction** is one of the core design principles of DASR.
The risk map does not blur anything.
Its sole purpose is to answer a single question:
> **"How likely is this pixel to produce visible shimmer?"**
Only after this decision has been made does the second stage of the pipeline determine how, where, and how much filtering should actually be applied.

## 3e. The Surgeon: Anisotropic Adaptive Low-Pass
Once the Risk Map has identified pixels that are likely to produce visible shimmer, DASR moves into the correction stage.
Unlike traditional anti-aliasing techniques, which apply a global filtering strategy across the entire image, DASR only modifies areas where instability has been detected.
The objective is simple:
**Remove temporal instability while preserving as much original detail as possible.**

A conventional blur treats every direction equally. This is often destructive because most aliasing artifacts are not random noise; they are generated by structured geometric patterns such as thin edges, fences, vegetation, distant objects, or repetitive surfaces.
Applying an isotropic blur to these structures reduces both the artifact and the useful information.
DASR instead uses an adaptive anisotropic approach.
The filter direction is calculated using a local **Structure Tensor analysis**.
The structure tensor examines the luminance gradient distribution inside a small neighborhood and determines whether the local image contains a dominant orientation.

From this information, DASR extracts:
* the main edge direction;
* the confidence that this direction is reliable;
* the perpendicular axis where filtering should occur.

The blur is then applied perpendicular to the detected structure.
This allows the shader to suppress unstable high-frequency variations while preserving directional information.

For example:
* a thin vertical fence will be filtered horizontally;
* a horizontal edge will be filtered vertically;
* diagonal structures will receive a matching diagonal correction.

The result is closer to a surgical operation rather than a traditional smoothing pass.

**Adaptive Tap System**
The amount of filtering is not fixed.
DASR dynamically adjusts the sampling radius according to the detected risk.
Low-risk areas receive minimal intervention.
Medium-risk areas activate additional samples.
High-risk areas can use the full three-tap directional filter.
This prevents unnecessary processing and avoids the typical TAA side effect where the entire image gradually loses micro-detail.
The final blur strength is controlled by the alias confidence produced by the Risk Map.
A pixel with weak evidence receives almost no correction.
A pixel with strong spatial and temporal instability receives stronger filtering.

**Tensor Confidence Modulation**
The Structure Tensor also provides a confidence value.
Not every region contains a clean directional structure.
Flat surfaces, noisy textures, or complex intersections may not have a reliable orientation.
When the tensor confidence is low, DASR automatically reduces the filtering strength.
This prevents incorrect blur directions and avoids damaging complex details.

**The Surgeon stage follows the same principle as the entire DASR pipeline:**
Do not remove detail to hide artifacts. Remove only the instability responsible for the artifact.

By separating detection from correction, DASR avoids the compromise of traditional global anti-aliasing solutions:
* no permanent blur;
* no full-screen softness;
* no unnecessary filtering of stable geometry.

The filter activates only where the image itself indicates that intervention is required.

## 3f. Phase-Aware Temporal Stabilization

Although the adaptive anisotropic filter removes most high-frequency shimmer, some temporal artifacts originate from alternating sampling phases rather than simple spatial instability.

One of the most common examples is moiré shimmer.

Unlike ordinary aliasing, moiré often exhibits an oscillating temporal behavior where the rendered pattern alternates between multiple valid sampling states as the camera moves.

A traditional temporal average cannot reliably distinguish this phenomenon from normal motion and may either leave the shimmer untouched or introduce visible ghosting.

To address this, DASR performs a lightweight phase-aware temporal analysis after the spatial filtering stage.

Instead of comparing only the current frame against the previous one, DASR temporarily stores two previous spatially filtered frames.

This allows the shader to recognize characteristic alternating temporal sequences such as: **A B A**

where the current frame resembles the frame from two frames earlier while differing from the immediately preceding one.

This behavior is typical of sampling-phase alternation rather than genuine scene motion.

When this pattern is detected, DASR locally blends only the alternating phase information while preserving the current spatial structure.

Several safeguards prevent false detections:

* local neighborhood matching
* motion rejection
* risk gating
* spatial neighborhood clamping

As a result, phase stabilization activates only where temporal alternation is both spatially plausible and supported by the existing instability detectors.
Unlike conventional temporal accumulation, this stage does not attempt to reconstruct missing image information.
Its purpose is specifically to suppress phase oscillation while minimizing ghosting and preserving local detail.

---

## 3g. Temporal Memory and Hysteresis
A temporal algorithm has a fundamental challenge: The decision made in the current frame can itself become unstable.
If a pixel is considered problematic in one frame but harmless in the next, a reactive filter may continuously turn on and off. This creates a secondary form of flickering, not caused by the game engine, but by the correction system itself.
To prevent this behavior, DASR introduces a lightweight temporal memory system.
At the end of every frame, the shader stores the current image together with the previously calculated alias confidence inside the History Buffer.
The next frame can then compare the new analysis with the previous decision.

The stored information is primarily used to stabilize temporal decisions and to support phase-aware analysis. Unlike conventional Temporal Anti-Aliasing, DASR does not rely on long-term accumulation or full image reconstruction. Previous frames are only consulted locally when they provide evidence of sampling-phase instability.

This is a deliberate design choice.
Unlike traditional Temporal Anti-Aliasing methods, DASR does not rely on temporal accumulation to reconstruct missing detail. The history buffer is only used as a memory of previous instability decisions.
This keeps the correction process spatially controlled and avoids the common temporal artifacts associated with history blending:
* ghosting behind moving objects;
* trailing artifacts;
* loss of fine texture detail;
* excessive softness caused by accumulated samples.

**Risk Hysteresis**
The temporal memory is mainly used through a hysteresis mechanism.
Instead of instantly replacing the previous alias confidence with the new value, DASR applies different response speeds depending on the direction of change.

When instability increases:
* the response is faster;
* the filter can react quickly to newly detected shimmer.

When instability decreases:
* the response is slower;
* the previous confidence fades gradually.

This asymmetry prevents the filter from rapidly oscillating between active and inactive states.

**In practical terms:**
A newly appearing shimmering fence, foliage pattern, or distant geometry can trigger correction almost immediately.
Once the instability disappears, the correction gently relaxes instead of abruptly disappearing.

**Why Not Use Full Temporal Accumulation?**
Many modern anti-aliasing techniques rely heavily on previous frames because they can reconstruct sub-pixel information and reduce visible jagged edges.
However, this approach has a cost.
When the underlying rendering pipeline provides unreliable motion information, poor depth precision, or unstable geometry sampling, temporal accumulation can amplify existing problems.
This is especially common in older or less sophisticated engines.
DASR takes a different approach.
The history buffer is not a source of image reconstruction.
It is a source of **confidence stabilization**.
> The shader does not ask:
> "How can I combine previous frames to create a smoother image?"
> Instead, it asks:
> "Was this pixel unstable before, and should I trust that information?"
This keeps the algorithm focused on its original goal:
detect unstable sampling patterns and suppress only the artifacts that are likely to become visible over time.

**Final Temporal Philosophy**
The memory stage completes the DASR pipeline:
* **Detect** identifies potential shimmer.
* **Predict** estimates whether instability will persist.
* **Stabilize** prevents the correction itself from flickering.

The result is a system that behaves more like an adaptive control loop than a traditional blur or temporal filter.

---

# 4. Performance Considerations and Shader Cost

DASR is designed as an adaptive post-processing algorithm.
Its goal is not to apply a complex filter uniformly across the entire image, but to analyze the frame, identify unstable regions, and concentrate processing only where visible shimmer is likely to occur.

The shader is divided into three main stages:
**1. Oracle Pass (Risk Analysis)
2. Surgeon Pass (Adaptive Spatial Filtering)
3. Phase Stabilization Pass
4. History Pass**

Each stage has a different performance profile.

**Oracle Pass: Detection Cost**
The detection stage is the most computationally expensive part of DASR because it gathers multiple sources of information before making a decision.
The main cost comes from the Grid-Brick Divergence detector.
It evaluates multiple sampling patterns around the current pixel:
* integer-offset cross samples;
* shifted cardinal samples;
* diagonal brick-wall samples.
These samples are compared to determine how sensitive the local structure is to sampling phase changes.
This allows DASR to identify potential shimmer sources before applying any correction.
Additional analysis includes:
* periodicity detection;
* depth evaluation;
* temporal history comparison.
The result is a detailed per-pixel risk estimation.
Although this requires more texture reads than a traditional blur pass, it replaces the need for aggressive full-screen filtering.

**Surgeon Pass: Adaptive Filtering Cost**
The correction stage is significantly cheaper because it only reacts to the information generated by the Risk Map.
The filter dynamically changes its behavior:
* low-risk pixels receive almost no processing;
* medium-risk pixels use a smaller directional filter;
* high-risk pixels activate the full anisotropic correction.
The maximum filter radius is intentionally limited.
DASR uses a small number of directional taps rather than a large-radius blur.
This avoids unnecessary texture sampling and preserves image sharpness.

**Phase Stabilization Pass:**
This stage performs a lightweight temporal phase analysis using only two previously stored spatial frames. Because the search is limited to a small local neighborhood and is activated only in high-risk regions, the additional cost remains moderate while providing a significant reduction of alternating moiré shimmer.

**Memory Pass: Minimal Temporal Overhead**
The history stage has a very small performance impact.
Unlike traditional temporal reconstruction techniques, DASR does not store multiple frames or perform expensive temporal accumulation.
The history buffer only stores:
* the previous frame color;
* the previous alias confidence value.
Its purpose is decision stabilization, not image reconstruction.

**Design Trade-Off**
DASR intentionally exchanges a small amount of shader complexity for better visual stability.

Traditional approaches often follow this pattern:
**Apply stronger global filtering - hide artifacts - lose detail**

DASR follows a different strategy:
**Analyze instability - locate problematic pixels - apply targeted correction**

**The additional analysis cost is compensated by:**
* reduced unnecessary blur;
* fewer false positives;
* preservation of fine details;
* better behavior on engines with weak anti-aliasing implementations.

**DASR is particularly useful in situations where conventional anti-aliasing solutions struggle:**
* older game engines;
* simulation software;
* distant geometry;
* thin structures;
* vegetation;
* fences and cables;
* repetitive patterns;
* low-contrast scenes where shimmer is difficult to notice until motion occurs.

**It is not intended to replace modern engine-integrated solutions with access to:**
* motion vectors;
* high quality depth buffers;
* temporal reconstruction data;
* neural upscaling pipelines.

Instead, DASR targets the large category of applications where those resources are unavailable or unreliable, providing a smarter adaptive solution through post-processing alone.

---

# 5. Known Limitations

Some artifacts originate from problems deeper inside the rendering pipeline and cannot be completely reconstructed after the final image has already been produced.

**Shadow Aliasing**
Shadow maps are generated before ReShade receives the final image.
If an engine produces unstable shadow silhouettes due to low resolution shadow maps, cascaded shadow transitions, or unstable shadow filtering, DASR can only reduce the visible shimmer.
It cannot recreate missing shadow information.

**Alpha-Tested and Dithered Materials**
Vegetation, fences, leaves, and other alpha-tested materials are among the most difficult cases.
These objects often rely on:
* transparency masking;
* temporal dithering;
* unstable coverage patterns.
DASR can reduce the visible flickering caused by sampling instability, but the underlying geometry information may already be lost.

**Engine Motion Artifacts**
DASR does not have access to engine motion vectors.
Its temporal prediction uses a lightweight local heuristic rather than full motion reconstruction.
This makes it widely compatible, but it cannot perfectly understand complex object motion, deformation, or particle systems.
The additional phase-aware stabilization stage further improves robustness against alternating sampling-phase artifacts, but it still cannot replace engine motion vectors for complex object motion.

**Poor Source Rendering**
No post-processing shader can fully compensate for insufficient source information.
Examples:
* extremely low-resolution shadow maps;
* missing geometry detail;
* aggressive engine optimizations;
* unstable depth precision.

DASR focuses on stabilizing the final image, not replacing missing rendering data.

**Depth Buffer Limitations**
Depth weighting depends on the quality and availability of the ReShade depth buffer.
Incorrect depth configuration may reduce or disable depth-based prioritization.
The shader will continue operating through the other detectors, but the distance-based weighting will not behave correctly.

**The Goal**
DASR is not designed to make every engine behave like a modern AAA renderer.
Its purpose is more specific:
To provide a smarter adaptive correction layer for applications where traditional solutions are limited, unreliable, or unavailable.
It does not hide all rendering problems.
It identifies the unstable parts of the image and reduces the artifacts that are most visible to human perception.

---

# 6. Recommended Settings and Tuning Philosophy

The default values are intended to provide a balanced configuration, but different engines and rendering pipelines produce different types of instability.
The goal is not to maximize filtering strength.
The goal is to find the minimum intervention required to eliminate visible shimmer while preserving detail.

**Grid-Brick Sensitivity:** The Grid-Brick detector is the primary shimmer sensor.
Increasing this value makes DASR more aggressive at detecting structures that are sensitive to pixel sampling changes.
Useful when:
* distant geometry flickers;
* thin structures disappear and reappear;
* vegetation or fences shimmer during movement.
Too high values may cause stable fine details to be considered risky.

**Temporal Sensitivity:** Controls how strongly previous-frame instability influences the final decision.
Increase when:
* shimmer appears mainly during camera movement;
* objects flicker only while moving;
* static screenshots look clean but motion reveals instability.
Lower when:
* moving objects trigger excessive filtering;
* the shader reacts too strongly to normal animation.

**Alias Response Curve:** Controls how quickly the correction strength grows once instability is detected.
Lower values create a smoother and more gradual response.
Higher values create a sharper reaction:
* weak instability receives little correction;
* strong instability receives aggressive correction.
This parameter is useful for balancing preservation of detail versus artifact removal.

**Anisotropic Strength:** Controls the intensity of the directional filtering stage.
Higher values:
* remove stronger shimmer;
* improve stability on difficult patterns.
Lower values:
* preserve more micro-detail;
* reduce smoothing.
Because DASR already detects where filtering is needed, this value can often be increased more safely than a traditional global blur.

**Tap Activation:** Controls when additional directional samples are activated.
Higher values:
* reduce processing;
* keep the image sharper.
Lower values:
* activate stronger correction earlier;
* help with extremely unstable scenes.

**Detector Weights:** The detector weights define the contribution of each analysis component.

**Grid-Brick Weight:** The main spatial instability detector.
Recommended to keep as the dominant component because it identifies the root cause of shimmer: sampling sensitivity.

**Temporal Weight:** Useful for scenes where instability appears mainly during movement.

**Periodicity Weight:**
Helpful for:
* repeated geometry;
* fences;
* rails;
* windows;
* patterned surfaces.

**Depth Weight:** Allows prioritizing distant geometry, where sub-pixel aliasing becomes more visible.

**Phase Moire Strength:** Controls how strongly the phase-aware stabilization stage blends alternating temporal phases once a valid phase pattern has been detected.
Higher values:
* reduce visible moiré shimmer more aggressively;
* improve stability on difficult high-frequency patterns.
Lower values:
* preserve more of the original temporal variation;
* reduce the possibility of over-stabilization.
This parameter only affects pixels where the phase detector has already identified a valid alternating pattern.

**Phase Alternation Sensitivity:** Controls how easily DASR recognizes alternating sampling-phase behavior across consecutive frames.
Higher values:
* detect weaker A/B/A alternation patterns;
* increase sensitivity to subtle temporal shimmer.
Lower values:
* require a stronger and more consistent phase alternation;
* reduce false detections in complex scenes.
In general, this parameter determines how selective the phase detector is before stabilization becomes active.

**Phase Motion Rejection:** Controls how aggressively DASR distinguishes genuine scene motion from phase alternation.
Higher values:
* reject temporal blending more often during camera movement;
* reduce ghosting and motion-related artifacts.
Lower values:
* allow phase stabilization to remain active more frequently;
* may improve shimmer reduction in some scenes, but can increase temporal smearing if set too low.

**Phase Outlier Rejection:** Controls the strength of the temporal outlier rejection stage.
This mechanism detects isolated one-frame deviations that differ significantly from their temporal neighborhood.
Higher values:
* suppress transient temporal spikes;
* reduce occasional fireflies, block artifacts and unstable one-frame fluctuations.
Lower values:
* preserve more of the original temporal variation;
* reduce the possibility of suppressing legitimate image changes.
This stage operates independently from the phase alternation detector and only activates when a clear temporal outlier is identified.

**Phase Risk Gate:** Defines the minimum instability confidence required before phase-aware stabilization is allowed to operate.
Higher values:
* restrict phase analysis to the most unstable regions;
* reduce unnecessary temporal processing.
Lower values:
* allow the phase detector to activate over a larger portion of the image;
* improve shimmer reduction on subtle patterns at the cost of increased sensitivity.
The Risk Gate ensures that phase stabilization complements the existing DASR detectors rather than operating uniformly across the entire frame.

## General Tuning Strategy - Recommended tuning workflow:
1. Start from default settings.
2. Test in motion, not only screenshots.
3. Identify the artifact type.
4. Adjust only the detector responsible for that behavior.
5. Increase filtering strength only after detection is correctly tuned.

**DASR should ideally behave invisibly.**
A correctly tuned configuration should not make the image look blurred.
It should simply make unstable details stop changing unpredictably over time.

---

# 7. Requirements & Compatibility

DASR is designed to run as a ReShade post-processing shader and does not require engine integration.

**Requirements**
* ReShade with shader support.
* A working depth buffer (required for depth-based weighting).
* Stable access to the backbuffer.
* Compatible rendering API supported by ReShade.

**Depth Buffer**
DASR can operate without depth information, but the depth weighting component will be disabled.
Because many modern engines use reversed depth or custom depth layouts (unity e.g.), correct ReShade depth buffer configuration may be required.
If depth data is unavailable or incorrect, DASR will continue to function using the remaining detectors.

**Compatibility**
DASR is especially useful for:
* older rendering engines;
* simulation software;
* games with limited anti-aliasing options;
* applications without motion vectors or temporal reconstruction data.
It is not intended to replace engine-integrated solutions such as modern temporal reconstruction pipelines, but rather to provide adaptive shimmer reduction where those systems are unavailable.

**Installation**
1. Install ReShade normally for the target application.
2. Copy the DASR shader file into your ReShade shader directory.
3. Enable the shader from the ReShade interface.
4. Configure the depth buffer settings if depth-based weighting is desired.
After installation, DASR should work with default parameters.
The recommended workflow is to first test the default configuration in motion, then adjust the tuning parameters according to the type of instability present in the scene.

---


