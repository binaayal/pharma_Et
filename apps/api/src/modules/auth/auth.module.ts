import { createSecretKey } from 'node:crypto';
import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { JwtModule } from '@nestjs/jwt';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { LoginThrottleService } from './login-throttle.service';

@Module({
  imports: [
    JwtModule.registerAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (config: ConfigService) => {
        // Built once. Handed a string, the JWT library rebuilds a key object on every sign
        // and verify — ~1.1 ms of CPU per authenticated request, measured, which at NFR-3.1's
        // 1,000 pharmacies was the largest single cost after the ORM. Same secret, same
        // tokens; only the per-request work goes.
        const key = createSecretKey(Buffer.from(config.getOrThrow<string>('JWT_SECRET')));
        return { secretOrKeyProvider: () => key };
      },
    }),
  ],
  controllers: [AuthController],
  providers: [AuthService, LoginThrottleService],
  exports: [JwtModule],
})
export class AuthModule {}
