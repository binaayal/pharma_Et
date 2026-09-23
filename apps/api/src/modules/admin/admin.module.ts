import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { ManagementController } from './management.controller';
import { ManagementService } from './management.service';

@Module({
  imports: [InventoryModule],
  controllers: [ManagementController],
  providers: [ManagementService],
})
export class AdminModule {}
