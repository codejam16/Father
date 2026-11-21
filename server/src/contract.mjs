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
  const sessionId = value.sessionId ?? null;
  const continuationId = value.continuationId ?? null;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (sessionId !== null && (typeof sessionId !== 'string' || !uuid.test(sessionId))) invalid('Invalid sessionId.');
  if (continuationId !== null && (!sessionId || typeof continuationId !== 'string' || !uuid.test(continuationId))) invalid('Invalid continuationId.');
  if (value.researchEnabled !== undefined && typeof value.researchEnabled !== 'boolean') invalid('Invalid researchEnabled.');
  const confirmedStepIds = value.confirmedStepIds ?? [];
  if (!Array.isArray(confirmedStepIds) || confirmedStepIds.length > 10 ||
      !confirmedStepIds.every((id) => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,40}$/.test(id))) invalid('Invalid confirmedStepIds.');
  return { frameId, capturedAt, question, task, image, history: normalizedHistory, selection,
    sessionId, continuationId, researchEnabled: value.researchEnabled ?? true, confirmedStepIds };
}

// A schema constrains shape; validate the model's values again before using them.
export const answerSchema = {
  type: 'object',
  properties: {
    answer: { type: 'string' },
    targetLabel: { type: ['string', 'null'] },
    box: { type: ['array', 'null'], items: { type: 'number' }, minItems: 4, maxItems: 4 },
    needsClearerView: { type: 'boolean' },
  },
  required: ['answer', 'targetLabel', 'box', 'needsClearerView'],
  additionalProperties: false,
};

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
  return { answer: value.answer.trim(), target, needsClearerView: value.needsClearerView };
}
