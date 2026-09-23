import { Controller, Get } from '@nestjs/common';
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
  health() {
    return {
      status: 'ok',
      contractVersion: CONTRACT_VERSION,
      supportedContractVersions: SUPPORTED_CONTRACT_VERSIONS,
      time: new Date().toISOString(),
    };
  }
}
