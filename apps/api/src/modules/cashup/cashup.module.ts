import { Module } from '@nestjs/common';
import { CashUpService } from './cash-up.service';

@Module({
  providers: [CashUpService],
  exports: [CashUpService],
})
export class CashUpModule {}
