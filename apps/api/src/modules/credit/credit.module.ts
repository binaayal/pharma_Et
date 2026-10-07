import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { CreditService } from './credit.service';

@Module({
  imports: [InventoryModule],
  providers: [CreditService],
  exports: [CreditService],
})
export class CreditModule {}
