import { Module } from '@nestjs/common';
import { CashUpModule } from '../cashup/cashup.module';
import { InventoryModule } from '../inventory/inventory.module';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

@Module({
  imports: [InventoryModule, CashUpModule],
  controllers: [SyncController],
  providers: [SyncService],
  exports: [SyncService],
})
export class SyncModule {}
