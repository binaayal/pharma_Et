import { Module } from '@nestjs/common';
import { ComplianceSwitch } from './compliance-switch';
import { LedgerController } from './ledger.controller';
import { LedgerService } from './ledger.service';

@Module({
  controllers: [LedgerController],
  providers: [LedgerService, ComplianceSwitch],
  exports: [LedgerService, ComplianceSwitch],
})
export class LedgerModule {}
