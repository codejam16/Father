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

const objectID = (id) => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(id);
function validateObjectGraph(objects, fail) {
  const byID = new Map(objects.map((object) => [object.id, object]));
  if (byID.size !== objects.length) fail();
  for (const object of objects) {
    const visited = new Set([object.id]);
    let parent = object.parentId;
    while (parent != null) {
      if (!byID.has(parent) || visited.has(parent)) fail();
      visited.add(parent);
      parent = byID.get(parent).parentId;
    }
  }
}

export function validateRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid('Expected a JSON object.');
  const frameId = text(value.frameId, 'frameId', 80);
  const capturedAt = text(value.capturedAt, 'capturedAt', 40);
  if (Number.isNaN(Date.parse(capturedAt))) invalid('capturedAt must be an ISO date.');
  const question = text(value.question, 'question', 1500);
  const task = text(value.task ?? '', 'task', 4000, true);
  const image = value.image;
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
  const history = value.history ?? [];
  if (!Array.isArray(history) || history.length > 8) invalid('history can contain at most eight messages.');
  const normalizedHistory = history.map((message) => {
    if (!message || !['user', 'assistant'].includes(message.role)) invalid('Invalid history role.');
    return { role: message.role, content: text(message.content, 'history content', 2000) };
  });
  const selection = value.selection == null ? null : validateBox(value.selection);
  const rawKnownTargets = value.knownTargets ?? [];
  if (!Array.isArray(rawKnownTargets) || rawKnownTargets.length > 6) invalid('At most six known targets are allowed.');
  const knownTargets = rawKnownTargets.map((object) => {
    if (!object || !objectID(object.id) || (object.parentId != null && !objectID(object.parentId)) ||
        !['visible', 'searching', 'dormant'].includes(object.state) || !['user', 'assistant'].includes(object.source) ||
        typeof object.isFocused !== 'boolean') invalid('Invalid known target.');
    const label = text(object.label, 'object label', 160);
    if (object.state !== 'visible' && object.box != null) invalid('Lost targets must not include stale coordinates.');
    return { id: object.id, label, parentId: object.parentId ?? null, source: object.source, state: object.state,
      box: object.state === 'visible' ? validateBox(object.box) : null, isFocused: object.isFocused };
  });
  validateObjectGraph(knownTargets, () => invalid('Invalid known target relationships.'));
  if (knownTargets.filter((object) => object.isFocused).length > 1) invalid('Only one target can be focused.');
  const rawSelections = value.selections ?? [];
  if (!Array.isArray(rawSelections) || rawSelections.length > 6) invalid('At most six selections are allowed.');
  const selections = rawSelections.map((object) => {
    if (!objectID(object?.id) || !knownTargets.some((known) => known.id === object.id && known.state === 'visible')) invalid('Selection must refer to a visible known target.');
    return { id: object.id, label: text(object.label, 'selection label', 160), box: validateBox(object.box) };
  });
  if (value.includeWebInfo !== undefined && typeof value.includeWebInfo !== 'boolean') invalid('includeWebInfo must be a boolean.');
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
    knownTargets, selections, sessionId, continuationId, researchEnabled: value.researchEnabled ?? true, confirmedStepIds, includeWebInfo: value.includeWebInfo === true,
    searchEveryQuestion: value.searchEveryQuestion === true };
}

// A schema constrains shape; validate the model's values again before using them.
export const answerSchema = {
  type: 'object',
  properties: {
    answer: { type: 'string' },
    targetLabel: { type: ['string', 'null'] },
    box: { type: ['array', 'null'], items: { type: 'number' }, minItems: 4, maxItems: 4 },
    needsClearerView: { type: 'boolean' },
    targets: { type: 'array', maxItems: 4, items: {
      type: 'object', additionalProperties: false,
      properties: {
        id: { type: 'string' }, parentId: { type: ['string', 'null'] }, label: { type: 'string' },
        box: { type: 'array', items: { type: 'number' }, minItems: 4, maxItems: 4 },
      }, required: ['id', 'parentId', 'label', 'box'],
    } },
  },
  required: ['answer', 'targetLabel', 'box', 'needsClearerView', 'targets'],
  additionalProperties: false,
};

export function validateAnswer(value, knownTargets = []) {
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
  let targets;
  if (value.targets !== undefined) {
    const fail = () => { throw new APIError(502, 'invalid_model_output', 'The model returned invalid object selections.'); };
    if (!Array.isArray(value.targets) || value.targets.length > 4) fail();
    targets = value.targets.map((object) => {
      if (!object || !objectID(object.id) || (object.parentId != null && !objectID(object.parentId)) ||
          typeof object.label !== 'string' || !object.label.trim() || object.label.length > 160) fail();
      try { validateBox(object.box); } catch { fail(); }
      return { id: object.id, parentId: object.parentId ?? null, label: object.label.trim(), box: object.box };
    });
    if (new Set(targets.map((object) => object.id)).size !== targets.length) fail();
    const updated = new Map(knownTargets.map((object) => [object.id, object]));
    for (const object of targets) updated.set(object.id, object);
    validateObjectGraph([...updated.values()], fail);
    // Parents precede their new child targets when both are in the answer.
    targets.sort((a, b) => {
      const depth = (object) => { let n = 0; for (let id = object.parentId; id != null; id = updated.get(id).parentId) n++; return n; };
      return depth(a) - depth(b);
    });
    if (value.needsClearerView) targets = [];
    if (!target && targets.length) target = { label: targets[0].label, box: targets[0].box };
  }
  return { answer: value.answer.trim(), target, ...(targets === undefined ? {} : { targets }), needsClearerView: value.needsClearerView };
}
