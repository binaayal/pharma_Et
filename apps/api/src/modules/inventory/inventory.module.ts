import { Module } from '@nestjs/common';
import { ChangeSeqService } from './change-seq.service';
import { InventoryService } from './inventory.service';

@Module({
  providers: [InventoryService, ChangeSeqService],
  exports: [InventoryService, ChangeSeqService],
})
export class InventoryModule {}
