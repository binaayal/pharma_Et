import { SetMetadata } from '@nestjs/common';

export const ALLOW_WHEN_SUSPENDED = 'allowWhenSuspended';

/**
 * Marks a route as reachable by a tenant whose subscription is suspended (ADR-016).
 *
 * The exemptions are **declared on the route and therefore countable**. An exemption list
 * that grew silently — or a guard that tried to infer intent from the HTTP verb — would
 * hollow BR-1.3 out one endpoint at a time, and nobody would be able to say what suspension
 * still blocks.
 *
 * Reserve it for two kinds of thing, and say which in a comment at the call site:
 *   - a **record** of something that already happened (a queued sale reaching the server);
 *   - an action that **ends** the suspension (submitting a payment proof).
 */
export const AllowWhenSuspended = () => SetMetadata(ALLOW_WHEN_SUSPENDED, true);
