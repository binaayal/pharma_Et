import { Injectable } from '@nestjs/common';

/**
 * The one switch in front of the regulated half (ADR-024).
 *
 * Off unless `CONTROLLED_DISPENSING=on`. ADR-024 permits turning it on only once A-1 is
 * verified against the EFDA retail-pharmacy directive and recorded in
 * `docs/compliance-sign-off.md`; until then every controlled operation is refused and
 * nothing is written. Read on every call rather than at boot, so the guardian suite can
 * exercise both states in one process — and so there is no cached "on" to forget about.
 */
@Injectable()
export class ComplianceSwitch {
  isOn(): boolean {
    return process.env.CONTROLLED_DISPENSING === 'on';
  }

  /** Throws the refusal every controlled path shares while the switch is off. */
  assertOn(): void {
    if (!this.isOn()) {
      throw new Error(
        'controlled dispensing is switched off until A-1 (the EFDA retail directive) is ' +
          'verified — ADR-024',
      );
    }
  }
}
