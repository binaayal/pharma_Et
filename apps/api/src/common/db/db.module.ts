import { Global, Module } from '@nestjs/common';
import { ScopedDbService } from './scoped-db.service';

/**
 * Global so that no module needs to import a DataSource to do its job — the scoped service
 * is always available, and reaching for anything else is conspicuous in review.
 */
@Global()
@Module({
  providers: [ScopedDbService],
  exports: [ScopedDbService],
})
export class DbModule {}
