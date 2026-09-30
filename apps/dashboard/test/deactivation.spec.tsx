// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { TenantBadge } from '../src/console/Console';
import { AccountDialog } from '../src/console/Tenants';
import type { PlatformTenant } from '../src/lib/api';

/**
 * ADR-025 — forced deactivation, as the platform admin meets it.
 *
 * A click is too cheap for an action that stops a pharmacy trading on our platform, so the
 * dialog asks for the reason the owner will be shown and for the pharmacy code typed out.
 */
const tenant: PlatformTenant = {
  id: '01930000-0000-7000-8000-000000000001',
  name: 'Abay Pharmacy',
  code: 'abay',
  status: 'active',
  deactivatedAt: null,
  deactivatedReason: null,
  createdAt: new Date().toISOString(),
  subscriptionState: 'active',
  currentPeriodEnd: null,
  suspendedReason: null,
  priceSantim: 100000,
  pendingProofs: 0,
  branchCount: 1,
  branchNames: 'Bole',
  ownerName: 'Abebe',
  ownerPhone: null,
};

describe('deactivating a pharmacy', () => {
  afterEach(cleanup);

  function open(onConfirm = vi.fn()) {
    render(
      <AccountDialog
        tenant={tenant}
        action="deactivate"
        busy={false}
        onClose={() => {}}
        onConfirm={onConfirm}
      />,
    );
    const confirm = screen.getByRole('button', { name: 'Deactivate account' });
    return { confirm: confirm as HTMLButtonElement, onConfirm };
  }

  it('will not go ahead without a reason and the pharmacy code', () => {
    const { confirm } = open();
    expect(confirm.disabled).toBe(true);

    fireEvent.change(screen.getByLabelText(/Reason/), { target: { value: 'too short' } });
    fireEvent.change(screen.getByLabelText(/Type the pharmacy code/), {
      target: { value: 'abay' },
    });
    expect(confirm.disabled).toBe(true);

    fireEvent.change(screen.getByLabelText(/Reason/), {
      target: { value: 'Selling without prescriptions.' },
    });
    fireEvent.change(screen.getByLabelText(/Type the pharmacy code/), {
      target: { value: 'tana' },
    });
    expect(confirm.disabled).toBe(true);
  });

  it('sends the reason once both are given', () => {
    const { confirm, onConfirm } = open();
    fireEvent.change(screen.getByLabelText(/Reason/), {
      target: { value: '  Selling without prescriptions.  ' },
    });
    fireEvent.change(screen.getByLabelText(/Type the pharmacy code/), {
      target: { value: 'ABAY' },
    });
    expect(confirm.disabled).toBe(false);
    fireEvent.click(confirm);
    expect(onConfirm).toHaveBeenCalledWith('Selling without prescriptions.');
  });

  it('shows "Deactivated" ahead of any billing state', () => {
    render(<TenantBadge tenant={{ ...tenant, status: 'deactivated' }} />);
    expect(screen.getByText('Deactivated')).toBeTruthy();
    expect(screen.queryByText('Active')).toBeNull();
  });
});
