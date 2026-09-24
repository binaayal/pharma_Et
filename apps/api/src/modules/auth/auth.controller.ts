import { Body, Controller, HttpCode, Ip, Post } from '@nestjs/common';
import {
  type LoginRequest,
  type LoginResponse,
  type RefreshRequest,
  loginRequest,
  refreshRequest,
} from '@pharmaet/contracts';
import { Public } from '../../common/auth/public.decorator';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { AuthService } from './auth.service';

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Post('login')
  @HttpCode(200)
  login(
    @Body(new ZodValidationPipe(loginRequest)) body: LoginRequest,
    @Ip() sourceIp: string,
  ): Promise<LoginResponse> {
    return this.auth.login(body, sourceIp);
  }

  /**
   * Exchanges a refresh token for a new session (ADR-019).
   *
   * `@Public()` because the whole point is that the access token has expired — requiring one
   * to get one would be circular. The refresh token is the credential here, and the guard
   * that rejects it everywhere else is what makes it safe to accept in this one place.
   */
  @Public()
  @Post('refresh')
  @HttpCode(200)
  refresh(
    @Body(new ZodValidationPipe(refreshRequest)) body: RefreshRequest,
  ): Promise<LoginResponse> {
    return this.auth.refresh(body);
  }
}
