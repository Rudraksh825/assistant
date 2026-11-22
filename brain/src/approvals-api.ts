import type { AppContext } from './core/context.js';
import type { Router } from './core/http.js';
import { invalid, isPlainObject } from './core/util.js';

/**
 * The routes a decision on an approval arrives through. They sit behind the bearer token like every other route;
 * the agent's shell cannot reach the API at all, and its sandbox cannot read the token.
 */
export function registerApprovalRoutes(r: Router, ctx: AppContext): void {
  const { repos, agent } = ctx;
  r.get('/approvals', ({ query }) => ({ items: repos.approvals.list(query.get('status') || undefined) }));
  r.post('/approvals/:id/approve', ({ params, body }) => {
    if (body.edits !== undefined && !isPlainObject(body.edits)) throw invalid('edits must be the whole edited input as a JSON object');
    return repos.approvals.approve(params.id!, body.edits, (a) => agent.executeApproval(a), (a, edited) => agent.checkApproval(a, edited));
  });
  r.post('/approvals/:id/deny', ({ params, body }) => repos.approvals.deny(params.id!, body.reason));
}
