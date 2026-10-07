import { Module } from '@nestjs/common';
import { CashUpModule } from '../cashup/cashup.module';
import { CreditModule } from '../credit/credit.module';
import { InventoryModule } from '../inventory/inventory.module';
import { LedgerModule } from '../ledger/ledger.module';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

@Module({
  imports: [InventoryModule, CashUpModule, LedgerModule, CreditModule],
  controllers: [SyncController],
  providers: [SyncService],
  exports: [SyncService],
})
export class SyncModule {}
