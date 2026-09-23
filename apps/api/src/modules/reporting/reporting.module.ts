import { Module } from '@nestjs/common';
import { CashUpModule } from '../cashup/cashup.module';
import { ReportingController } from './reporting.controller';
import { ReportingService } from './reporting.service';

@Module({
  imports: [CashUpModule],
  controllers: [ReportingController],
  providers: [ReportingService],
})
export class ReportingModule {}
