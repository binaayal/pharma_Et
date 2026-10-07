import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { PayablesService } from './payables.service';

@Module({
  imports: [InventoryModule],
  providers: [PayablesService],
  exports: [PayablesService],
})
export class PayablesModule {}
