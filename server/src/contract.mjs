export class APIError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const invalid = (message) => { throw new APIError(400, 'invalid_request', message); };

function text(value, name, max, allowEmpty = false) {
  if (typeof value !== 'string' || value.length > max || (!allowEmpty && !value.trim())) {
    invalid(`${name} must be ${allowEmpty ? 'at most' : '1 to'} ${max} characters.`);
  }
  return value.trim();
}

export function validateBox(box) {
  if (!Array.isArray(box) || box.length !== 4 ||
      !box.every((v) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1000) ||
      box[0] >= box[2] || box[1] >= box[3]) {
    invalid('box must be [ymin, xmin, ymax, xmax], nonempty and normalized to 0–1000.');
  }
  return box;
}

/// Shared JPEG checks for every camera image that crosses the API boundary.
export function validateImage(image) {
  if (!image || image.mimeType !== 'image/jpeg') invalid('A JPEG image is required.');
  if (![image.width, image.height].every((n) => Number.isInteger(n) && n > 0 && n <= 2048)) {
    invalid('Image dimensions must be integers between 1 and 2048.');
  }
  if (typeof image.base64 !== 'string' || image.base64.length > 2_000_000 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(image.base64)) invalid('Invalid image encoding.');
  const bytes = Buffer.from(image.base64, 'base64');
  if (bytes.length < 4 || bytes.length > 1_500_000 || bytes.toString('base64') !== image.base64 ||
      bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes.at(-2) !== 0xff || bytes.at(-1) !== 0xd9) {
    invalid('Image must be a base64-encoded JPEG smaller than 1.5 MB.');
  }
  return image;
}

export function validateRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid('Expected a JSON object.');
  const frameId = text(value.frameId, 'frameId', 80);
  const capturedAt = text(value.capturedAt, 'capturedAt', 40);
  if (Number.isNaN(Date.parse(capturedAt))) invalid('capturedAt must be an ISO date.');
  const question = text(value.question, 'question', 1500);
  const task = text(value.task ?? '', 'task', 4000, true);
  const image = validateImage(value.image);
  // Optional close-up of the same moment (around the user's fingertip), with where it sits in the full image.
  let detailImage = null;
  if (value.detailImage != null) {
    const detail = value.detailImage;
    if (!detail || typeof detail !== 'object') invalid('Invalid detailImage.');
    detailImage = { ...validateImage(detail), box: validateBox(detail.box) };
  }
  const history = value.history ?? [];
  if (!Array.isArray(history) || history.length > 8) invalid('history can contain at most eight messages.');
  const normalizedHistory = history.map((message) => {
    if (!message || !['user', 'assistant'].includes(message.role)) invalid('Invalid history role.');
    return { role: message.role, content: text(message.content, 'history content', 2000) };
  });
  const selection = value.selection == null ? null : validateBox(value.selection);
  // Spots the user's fingertip rested on while asking, in order, as [y, x] (0-1000).
  let pointedAt = [];
  if (value.pointedAt != null) {
    if (!Array.isArray(value.pointedAt) || value.pointedAt.length > 4 || !value.pointedAt.every((point) =>
      Array.isArray(point) && point.length === 2 && point.every((n) => Number.isFinite(n) && n >= 0 && n <= 1000))) {
      invalid('pointedAt must be up to four [y, x] points between 0 and 1000.');
    }
    pointedAt = value.pointedAt.map(([y, x]) => [Math.round(y), Math.round(x)]);
  }
  if (value.includeWebInfo !== undefined && typeof value.includeWebInfo !== 'boolean') invalid('includeWebInfo must be a boolean.');
  if (value.guided !== undefined && typeof value.guided !== 'boolean') invalid('guided must be a boolean.');
  const sessionId = value.sessionId ?? null;
  const continuationId = value.continuationId ?? null;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (sessionId !== null && (typeof sessionId !== 'string' || !uuid.test(sessionId))) invalid('Invalid sessionId.');
  if (continuationId !== null && (!sessionId || typeof continuationId !== 'string' || !uuid.test(continuationId))) invalid('Invalid continuationId.');
  if (value.researchEnabled !== undefined && typeof value.researchEnabled !== 'boolean') invalid('Invalid researchEnabled.');
  if (value.searchEveryQuestion !== undefined && typeof value.searchEveryQuestion !== 'boolean') invalid('Invalid searchEveryQuestion.');
  const confirmedStepIds = value.confirmedStepIds ?? [];
  if (!Array.isArray(confirmedStepIds) || confirmedStepIds.length > 10 ||
      !confirmedStepIds.every((id) => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,40}$/.test(id))) invalid('Invalid confirmedStepIds.');
  return { frameId, capturedAt, question, task, image, history: normalizedHistory, selection,
    sessionId, continuationId, researchEnabled: value.researchEnabled ?? true, confirmedStepIds, includeWebInfo: value.includeWebInfo === true,
    searchEveryQuestion: value.searchEveryQuestion === true, guided: value.guided === true, detailImage, pointedAt };
}

// A schema constrains shape; validate the model's values again before using them.
export const answerSchema = {
  type: 'object',
  properties: {
    answer: { type: 'string' },
    targetLabel: { type: ['string', 'null'] },
    box: { type: ['array', 'null'], items: { type: 'number' }, minItems: 4, maxItems: 4 },
    needsClearerView: { type: 'boolean' },
    pictureOf: { type: ['string', 'null'] },
    // Kept deliberately simple: Gemini rejects schemas with nested, size-limited arrays as too complex.
    // Limits (beats, points, ranges) are enforced by validateAnnotations instead.
    annotations: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          caption: { type: 'string' },
          say: { type: 'string' },
          box: { type: ['array', 'null'], items: { type: 'number' } },
          path: { type: ['array', 'null'], items: { type: 'number' } },
          label: { type: ['string', 'null'] },
          to: { type: ['array', 'null'], items: { type: 'number' } },
          zoom: { type: 'boolean' },
          region: { type: ['array', 'null'], items: { type: 'number' } },
        },
        required: ['caption', 'say', 'box', 'path', 'label', 'to', 'zoom', 'region'],
      },
    },
  },
  required: ['answer', 'targetLabel', 'box', 'needsClearerView', 'pictureOf', 'annotations'],
  additionalProperties: false,
};

export const boxInstruction = `Highlighting is one of the most useful things you do. When the user asks for help with, about or where something visible is, return targetLabel and box for the item your answer is about. For on-screen tasks, box the exact button, menu item, icon or setting to click or tap next.
Box accurately: find the item by its distinguishing features (shape, colour, text on it, position relative to nearby things) and put the box edges on its visible outline, not around the general area. When several similar items exist, box the specific one meant.`;

export const pictureInstruction = `REFERENCE PICTURES. pictureOf: the plain everyday name of the one object to show, as it would be titled in an encyclopedia or shop (e.g. "tweezers", "Phillips screwdriver", "spudger", "jumper wire"), never mixed with the task or the user's situation when the user asks what something looks like, says they don't know or can't find it, or asks to see a picture of it. The app then shows a photo of it on screen. Use the specific item you mean, not a vague category. Otherwise null; never for something you are already circling in the camera view.`;

export const walkthroughInstruction = `VISUAL WALKTHROUGHS. Return annotations (otherwise an empty list) whenever the user asks to explain, walk through or trace something visible: a diagram, circuit, schematic, chart, map, flowchart or drawing, or how something goes, gets, flows or moves from one place to another ("how does it go from A to B?"). The app freezes this image and draws the beats over it, one at a time, while the say lines are spoken.
Give 2 to 6 ordered beats. Every beat has: caption (under 12 words), say (1–2 short spoken sentences), box, path, label, to, zoom, region. A beat needs at least one of box, path or region; unused fields are null (zoom false).
- path: REQUIRED for any "from X to Y", flow or route question. A flat list y1, x1, y2, x2, … (2 to 24 points, 0..1000, top-left origin) in the direction of travel. The app draws it as an arrow, so trace the drawn line exactly:
  • First point exactly where the line leaves the start (e.g. the tip of pin A); last point exactly where it reaches the end (e.g. the tip of pin B). Never stop partway.
  • One point at EVERY corner or turn of the drawn line, in order. A zigzag with 4 turns needs all 4 turn points. Count the turns before answering.
  • Each point sits ON the line (on a dash for dashed lines). Never cut across empty space between turns or skip a section.
  • Prefer one beat whose path runs the whole route from start to end; other beats can box the start and end.
- box: [ymin,xmin,ymax,xmax] around the part a beat is about.
- label: a 1–4 word tag for that part, e.g. "R1 · 220 Ω" or "Point A".
- to: when one part affects or connects to another ("the switch controls the LED"), the second part's box; box is the first part. The app draws a curved arrow between them.
- zoom: true when the part in box is small (markings, colour bands, pins, tiny text): the app shows a magnified bubble.
- region: a flat list y1, x1, y2, x2, … (3+ points) outlining an area to shade, e.g. one loop or one section of a chart.
Use the visual that fits each beat; a good circuit explanation usually has a labelled start box, a path along the wires, any connection arrow, and a zoom on small markings.
Example for "how does the current get from A to B?" (coordinates illustrative): [{"caption":"Start at point A","say":"The current starts here, at point A.","box":[120,80,200,160],"path":null,"label":"A","to":null,"zoom":false,"region":null},{"caption":"Through the resistor","say":"It flows along the top wire and through the resistor.","box":null,"path":[160,160,160,520,160,800],"label":null,"to":null,"zoom":false,"region":null},{"caption":"The resistor's value","say":"Its bands read 220 ohms.","box":[130,480,190,560],"path":null,"label":"220 Ω","to":null,"zoom":true,"region":null},{"caption":"Down to point B","say":"Then down the right side to point B.","box":null,"path":[160,800,700,800],"label":"B","to":null,"zoom":false,"region":null}]
Narrate the say lines in order as one natural explanation, and keep answer a complete short explanation on its own. Answer explanation questions this way rather than as guided steps.`;

/// Walkthrough beats from the model: drop malformed parts instead of failing the answer.
export function validateAnnotations(value) {
  if (!Array.isArray(value)) return [];
  const inRange = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1000;
  const point = (p) => Array.isArray(p) && p.length === 2 && p.every(inRange);
  // Accept the flat form the model is asked for (y1, x1, y2, x2, …) and the nested [[y, x], …] form.
  const toPath = (raw) => {
    if (!Array.isArray(raw)) return null;
    const pairs = raw.every((v) => typeof v === 'number')
      ? (raw.length % 2 === 0 ? Array.from({ length: raw.length / 2 }, (_, i) => [raw[2 * i], raw[2 * i + 1]]) : null)
      : raw;
    return pairs && pairs.length >= 2 && pairs.length <= 24 && pairs.every(point) ? pairs : null;
  };
  const toRegion = (raw) => {
    const pairs = toPath(raw);
    return pairs && pairs.length >= 3 ? pairs : null;
  };
  const beats = [];
  for (const beat of value.slice(0, 8)) {
    if (!beat || typeof beat.caption !== 'string' || !beat.caption.trim()) continue;
    let box = null;
    if (beat.box != null) { try { box = validateBox(beat.box); } catch { box = null; } }
    const path = toPath(beat.path);
    const region = toRegion(beat.region);
    if (!box && !path && !region) continue;
    let to = null;
    if (box && beat.to != null) { try { to = validateBox(beat.to); } catch { to = null; } }
    const label = typeof beat.label === 'string' && beat.label.trim() ? beat.label.trim().slice(0, 40) : null;
    const zoom = beat.zoom === true && Boolean(box);
    const caption = beat.caption.trim().slice(0, 120);
    const say = typeof beat.say === 'string' && beat.say.trim() ? beat.say.trim().slice(0, 400) : caption;
    beats.push({ caption, say, box, path, label, to, zoom, region });
  }
  return beats;
}

export function validateAnswer(value) {
  if (!value || typeof value.answer !== 'string' || !value.answer.trim() || value.answer.length > 2000 ||
      typeof value.needsClearerView !== 'boolean') {
    throw new APIError(502, 'invalid_model_output', 'The model returned an unusable answer. Please try again.');
  }
  let target = null;
  // Do not draw a target when the model says the view is insufficient.
  if (value.box != null && !value.needsClearerView) {
    try {
      validateBox(value.box);
      if (typeof value.targetLabel !== 'string' || !value.targetLabel.trim() || value.targetLabel.length > 160) {
        throw new Error('Invalid target label');
      }
      target = { label: value.targetLabel.trim(), box: value.box };
    } catch {
      throw new APIError(502, 'invalid_model_output', 'The model returned an invalid target position.');
    }
  }
  const annotations = value.needsClearerView ? [] : validateAnnotations(value.annotations);
  return { answer: value.answer.trim(), target, needsClearerView: value.needsClearerView, annotations, pictureOf: validatePictureOf(value.pictureOf) };
}

/// A short search phrase for a reference picture, or null.
export function validatePictureOf(value) {
  if (typeof value !== 'string') return null;
  const phrase = value.trim().replace(/\s+/g, ' ');
  return phrase && phrase.length <= 80 ? phrase : null;
}
