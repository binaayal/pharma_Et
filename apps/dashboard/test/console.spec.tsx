// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Console } from '../src/console/Console';

/**
 * The web console is the platform console, and only that (docs/prototype screens 20–26).
 *
 * It once carried a tenant console — cash reconciliation, sales, stock, audit — which the
 * design never asked for: owners run their pharmacy from the phone. These pin the shape.
 */
describe('the platform console', () => {
  const fetchMock = vi.fn();
  const json = (body: unknown) => ({ ok: true, json: async () => body });

  beforeEach(() => {
    sessionStorage.clear();
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('opens on the platform sign-in, not a pharmacy one', () => {
    render(<Console />);
    expect(screen.getByText('Platform console')).toBeTruthy();
    expect(screen.getByLabelText('Email')).toBeTruthy();
    expect(screen.queryByText(/Pharmacy code/i)).toBeNull();
  });

  it('has exactly the prototype navigation, and no tenant pages', async () => {
    sessionStorage.setItem('pharmaet.platform', 'tok');
    fetchMock.mockImplementation(async (url: string) =>
      url.includes('/platform/signup-requests')
        ? json([
            {
              id: 'r1',
              pharmacyName: 'Adera',
              ownerName: 'Helen Bekele',
              phone: '+251921184477',
              city: 'Addis Ababa',
              branchBand: '1',
              status: 'pending',
              submittedAt: new Date().toISOString(),
              decidedAt: null,
              decisionReason: null,
              tenantId: null,
            },
          ])
        : json([]),
    );
    render(<Console />);

    await waitFor(() => expect(screen.getAllByText('1').length).toBeGreaterThan(0));
    for (const item of ['Overview', 'Sign-up requests', 'Tenants', 'Payments', 'Subscriptions']) {
      expect(screen.getAllByText(new RegExp(item)).length).toBeGreaterThan(0);
    }
    for (const gone of [
      'Cash reconciliation',
      'Sales summary',
      'Stock & expiry',
      'Synced sales',
      'Audit trail',
    ]) {
      expect(screen.queryByText(gone)).toBeNull();
    }
  });

  it('shows a sign-up request with the phone to call before approving', async () => {
    sessionStorage.setItem('pharmaet.platform', 'tok');
    fetchMock.mockImplementation(async (url: string) =>
      url.includes('/platform/signup-requests')
        ? json([
            {
              id: 'r1',
              pharmacyName: 'Adera Pharmacy',
              ownerName: 'Helen Bekele',
              phone: '+251921184477',
              city: 'Addis Ababa',
              branchBand: '1',
              status: 'pending',
              submittedAt: new Date().toISOString(),
              decidedAt: null,
              decisionReason: null,
              tenantId: null,
            },
          ])
        : json([]),
    );
    render(<Console />);
    fireEvent.click((await screen.findAllByText(/Sign-up requests/))[0]);

    expect(await screen.findByText('Adera Pharmacy · request')).toBeTruthy();
    expect(screen.getByText(/Call the number/)).toBeTruthy();
    fireEvent.click(screen.getByText(/Approve & open account/));
    expect(screen.getByLabelText('Starting PIN')).toBeTruthy();
  });
});
