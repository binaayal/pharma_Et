import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { BillingController, PlatformController, SignupController } from './billing.controller';
import { BillingService } from './billing.service';
import { PlatformAuthService } from './platform-auth.service';
import { ProofStorageService } from './proof-storage.service';
import { SignupService } from './signup.service';

@Module({
  // AuthModule re-exports JwtModule, so the platform guard verifies tokens with the same
  // key. The `typ` claim is what separates the two audiences, not a second secret — one
  // signing key with an explicit audience claim is easier to rotate and harder to confuse
  // than two keys nobody remembers which is which.
  imports: [AuthModule],
  controllers: [BillingController, PlatformController, SignupController],
  providers: [BillingService, PlatformAuthService, ProofStorageService, SignupService],
  exports: [BillingService],
})
export class BillingModule {}
