import { randomUUID } from 'node:crypto';
import { APIError } from './contract.mjs';

export const emptyMemory = () => ({ goal: '', facts: [], openQuestions: [], plan: [] });

// Process-local, bounded task memory. Never retain camera images or API keys.
export class TaskSessions {
  constructor({ limit = 100, ttl = 30 * 60_000, now = Date.now } = {}) {
    this.entries = new Map();
    this.limit = limit;
    this.ttl = ttl;
    this.now = now;
  }

  async run(input, operation) {
    const now = this.now();
    for (const [key, value] of this.entries) {
      if (!value.busy && now - value.updated > this.ttl) this.entries.delete(key);
    }
    let session = this.entries.get(input.sessionId);
    if (!session) {
      if (input.continuationId) throw new APIError(409, 'task_expired', 'Task research expired or the backend restarted. Ask your question again.');
      if (this.entries.size >= this.limit) {
        const oldest = [...this.entries].filter(([, value]) => !value.busy).sort((a, b) => a[1].updated - b[1].updated)[0];
        if (!oldest) throw new APIError(503, 'tasks_busy', 'The backend is busy. Please try again later.');
        this.entries.delete(oldest[0]);
      }
      session = { memory: emptyMemory(), sources: [], reports: [], pending: null, task: input.task, updated: now, busy: false };
      this.entries.set(input.sessionId, session);
    }
    if (session.busy) throw new APIError(409, 'task_busy', 'Another question is still processing for this task.');
    const draft = structuredClone(session);
    if (draft.task !== input.task) {
      if (input.continuationId) throw new APIError(409, 'task_changed', 'The task changed. Ask your question again.');
      draft.memory = emptyMemory(); draft.sources = []; draft.reports = []; draft.pending = null; draft.task = input.task;
    }
    if (input.continuationId) {
      const pending = draft.pending;
      if (!pending || pending.id !== input.continuationId || pending.expires < now || pending.question !== input.question) {
        throw new APIError(409, 'research_expired', 'Research continuation expired. Ask your question again.');
      }
      if (pending.frameId === input.frameId) throw new APIError(400, 'fresh_frame_required', 'A fresh camera frame is required after research.');
    } else {
      draft.pending = null;
    }
    for (const id of input.confirmedStepIds ?? []) {
      const step = draft.memory.plan.find((step) => step.id === id);
      if (step) step.completed = true;
    }
    session.busy = true;
    try {
      const result = await operation(draft);
      this.entries.set(input.sessionId, { ...draft, updated: this.now(), busy: false });
      return result;
    } finally {
      session.busy = false;
    }
  }
}

export function continuation(session, request, researchSteps) {
  const id = randomUUID();
  session.pending = { id, question: request.question, frameId: request.frameId, researchSteps, expires: Date.now() + 120_000 };
  return id;
}

/// Marks steps the USER said they finished ("ok", "done", "what's next") as completed.
/// Only ids that exist in the plan are used; the model never completes steps from images alone.
export function applyUserCompletedSteps(memory, ids) {
  if (!Array.isArray(ids)) return memory;
  const wanted = new Set(ids.filter((id) => typeof id === 'string').slice(0, 10));
  return { ...memory, plan: memory.plan.map((step) => (wanted.has(step.id) ? { ...step, completed: true } : step)) };
}

export function mergeMemory(previous, proposed) {
  const fail = () => { throw new APIError(502, 'invalid_task_state', 'The assistant returned invalid task details. Please try again.'); };
  const short = (value, max) => typeof value === 'string' && value.length <= max;
  if (!proposed || !short(proposed.goal, 600) ||
      !Array.isArray(proposed.facts) || proposed.facts.length > 12 || !proposed.facts.every((v) => short(v, 300)) ||
      !Array.isArray(proposed.openQuestions) || proposed.openQuestions.length > 8 || !proposed.openQuestions.every((v) => short(v, 300)) ||
      !Array.isArray(proposed.plan) || proposed.plan.length > 10) fail();
  const ids = new Set();
  const plan = proposed.plan.map((step) => {
    if (!step || !/^[a-zA-Z0-9_-]{1,40}$/.test(step.id ?? '') || !short(step.text, 400) || !step.text.trim() || ids.has(step.id)) fail();
    ids.add(step.id);
    const old = previous.plan.find((old) => old.id === step.id && old.text === step.text);
    // Completion is controlled by explicit user confirmation, never model output.
    return { id: step.id, text: step.text, completed: old?.completed === true };
  });
  return { goal: proposed.goal, facts: proposed.facts, openQuestions: proposed.openQuestions, plan };
}
