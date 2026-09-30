import { Controller, Get, Ip } from '@nestjs/common';
import { CONTRACT_VERSION, SUPPORTED_CONTRACT_VERSIONS } from '@pharmaet/contracts';
import { Public } from '../../common/auth/public.decorator';

@Controller('health')
export class HealthController {
  /**
   * Liveness, plus the contract versions this instance serves — so a rolling deploy can be
   * checked for the N-1 window still being honoured (ADR-009) without reading the code.
   */
  @Public()
  @Get()
  health(@Ip() clientIp: string) {
    return {
      status: 'ok',
      // The commit this image was built from (Dockerfile ARG APP_COMMIT). CD waits for it
      // to change before smoking the live URL, so it tests the release it just shipped.
      commit: process.env.APP_COMMIT ?? 'dev',
      // The caller's own address as the server sees it — the one-look check that TRUST_PROXY
      // is right for the host (docs/engineering/hosting.md). If this shows the host's proxy
      // rather than your own public IP, every pharmacy shares one login-throttle counter.
      clientIp,
      contractVersion: CONTRACT_VERSION,
      supportedContractVersions: SUPPORTED_CONTRACT_VERSIONS,
      time: new Date().toISOString(),
      // Whether the regulated half is live (ADR-024). Terminals read it to show or hide
      // controlled dispensing; the server enforces it regardless of what a terminal shows.
      features: { controlledDispensing: process.env.CONTROLLED_DISPENSING === 'on' },
    };
  }
}
