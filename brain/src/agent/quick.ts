import Anthropic from '@anthropic-ai/sdk';
import type { AppContext, QuickRequest } from '../core/context.js';
import { HttpError } from '../core/util.js';
import type { Engine } from './engine.js';

/** USD per million tokens, [input, output]. Only the direct API path needs it: the Agent SDK reports its own cost. */
const PRICES: [RegExp, number, number][] = [
  [/haiku-5-5/, 0.1, 0.5],
  [/sonnet-5-5/, 2, 10],
  [/opus-5-5/, 4, 20],
  [/fable-5-2/, 8, 40],
];
// An unknown model is priced as the dearest one so the budget errs on the careful side.
const priceOf = (model: string) => PRICES.find(([re]) => re.test(model)) ?? PRICES[PRICES.length - 1]!;

export const budgetSpent = () => new HttpError(429, 'budget_spent', 'The agent budget is spent; background work is paused until it resets');

export function createQuick(ctx: AppContext, engine: Engine) {
  return async function quick(req: QuickRequest): Promise<string> {
    const trigger = req.trigger ?? 'event';
    if (trigger !== 'user' && !ctx.cost.canSpendBackground()) throw budgetSpent();
    const model = ctx.config.get().models.fast;
    const system = req.system ?? 'Answer directly and briefly.';
    const apiKey = ctx.config.secret('ANTHROPIC_API_KEY');

    if (!apiKey) {
      const res = await engine.run({ kind: req.kind, trigger, model, billing: 'login', prompt: req.prompt, system, schema: req.schema, effort: 'low', maxTurns: req.schema ? 4 : 1 });
      if (!res.ok) throw new HttpError(502, 'agent_failed', res.error ?? 'quick call failed');
      return req.schema && res.structured !== undefined ? JSON.stringify(res.structured) : res.text;
    }

    const run = ctx.cost.start({ kind: req.kind, trigger, model, billing: 'api' });
    try {
      const res = await new Anthropic({ apiKey }).messages.create({
        model,
        max_tokens: req.maxTokens ?? 4096,
        system,
        messages: [{ role: 'user', content: req.prompt }],
        output_config: { effort: 'low', ...(req.schema && { format: { type: 'json_schema', schema: req.schema } }) },
      });
      const [, inPrice, outPrice] = priceOf(model);
      const u = res.usage;
      const usage = {
        inputTokens: u.input_tokens + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0),
        outputTokens: u.output_tokens,
        costUsd: (u.input_tokens * inPrice + (u.cache_creation_input_tokens ?? 0) * inPrice * 1.25 + (u.cache_read_input_tokens ?? 0) * inPrice * 0.1 + u.output_tokens * outPrice) / 1e6,
      };
      if (res.stop_reason === 'refusal' || res.stop_reason === 'max_tokens') {
        ctx.cost.finish(run.id, { status: 'error', ...usage, summary: res.stop_reason });
        throw new HttpError(502, 'agent_failed', res.stop_reason === 'refusal' ? 'The model declined this request' : 'The reply was cut off at max_tokens');
      }
      const text = res.content.map((b) => (b.type === 'text' ? b.text : '')).join('');
      ctx.cost.finish(run.id, { status: 'ok', ...usage, summary: text.slice(0, 200) });
      ctx.repos.health.set('agent:api', 'ok');
      return text;
    } catch (err) {
      if (err instanceof HttpError) throw err;
      ctx.cost.finish(run.id, { status: 'error', summary: (err as Error).message.slice(0, 200) });
      if (err instanceof Anthropic.AuthenticationError) ctx.repos.health.set('agent:api', 'error');
      throw new HttpError(502, 'agent_failed', err instanceof Anthropic.APIError ? `Claude API ${err.status ?? ''}: ${err.message}` : (err as Error).message);
    }
  };
}
