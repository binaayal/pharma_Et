import { Module } from '@nestjs/common';
import { CashUpModule } from '../cashup/cashup.module';
import { DailySummaryService } from './daily-summary.service';
import { ReportingController } from './reporting.controller';
import { ReportingService } from './reporting.service';
import { SalesSummaryService } from './sales-summary.service';
import { StockReportService } from './stock-report.service';

@Module({
  imports: [CashUpModule],
  controllers: [ReportingController],
  providers: [ReportingService, SalesSummaryService, StockReportService, DailySummaryService],
})
export class ReportingModule {}
