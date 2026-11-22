# Question-aware highlighting review

Implemented on `experiment/apple-foreground-masks`. This branch has a different
tracking implementation from `starter/visual-assistant`; these changes do not
merge unrelated scanner features or change local signing configuration.

## Findings and changes

| Finding | Resulting behavior |
| --- | --- |
| The UI drew only fresh foreground masks. A small release button that Vision did not segment disappeared completely. | Healthy tracks keep a translucent filled-area fallback; no corner boxes are drawn. A returned silhouette remains actual segmentation, not an oval painted over a bounding box. |
| The model's object list did not distinguish the current action target from a contextual parent. Earlier objects stayed lit. | Explicit object/part and primary/context metadata. Only the current answer's primary records glow; a new question hides old paint while preserving identity/focus for follow-ups. A failed request therefore leaves no old action cue. |
| Seeding an existing ID returned early and discarded corrected camera coordinates. | New answers re-seed from their actual source frame, including existing IDs. An expired frame clears presentation and gives a visible request to ask again. |
| Every target in a multi-object response became focused in succession. | Six distinct primary matches are supported, with no arbitrary single focus after a plural answer. Singular ambiguity asks for clarification. |
| Fresh masks reset the target's tracker to the mask bounds; approximate part/object association could enlarge the target. | Fresh whole-object masks re-anchor positional tracking to prevent drift. Part-mask geometry is stricter, and parts never expand onto an enclosing object. Low-confidence or parent-sized drifting part tracks are discarded. |
| Foreground geometry could revive a lost identity without proving it was the same object. | The mask worker processes current visible primary tracks. Lost objects need a new visual answer for re-identification, instead of mask-only reassociation to a similar bottle. |
| Empty arrays could fall back to legacy coordinates, and the legacy target could select a parent before its child. | Explicit arrays are authoritative, including `[]`. Legacy clients receive a primary component as their single pointer. |

The model instruction applies to all visible objects and controls, with bottle,
latch, cap, switch and screw examples. It explicitly avoids assuming a bottle
has a push-release mechanism when it cannot be seen. The array limit is six,
including required ancestors, to match the phone's bounded inventory. If more
items are visible, the assistant should state that it is showing six at a time.

## Validation and practical limits

Node tests use fake model replies and exercise request/response contracts,
plural targets, component identity and geometry, ambiguous/empty answers,
backward compatibility and ordinary agent/research flows. They do not measure
Gemini's actual visual accuracy. Native XCTest cases cover presentation scope,
focus, legacy response decoding and part-mask association. Xcode and physical
camera tests are unavailable in the authoring environment, so those native tests
and device performance are still unverified.

Apple's foreground segmenter identifies noticeable foreground instances; it is
not guaranteed to produce separate masks for a button or cap. A filled-area fallback
is intentionally a location cue, not a promise of pixel-perfect segmentation.
Accuracy still depends on the AI seeing the actual control. Tiny, blurry,
reflective, obscured or visually identical components may need a closer view.
Tracking between fresh masks is an approximation and can drift with fast motion,
perspective changes or occlusion. Coordinates from an expired source frame are
never reused as current coordinates. No extra provider requests, periodic cloud
analysis, or automatic retries were added.
