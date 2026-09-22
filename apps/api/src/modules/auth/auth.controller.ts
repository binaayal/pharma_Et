import { Body, Controller, HttpCode, Post } from '@nestjs/common';
import { type LoginRequest, type LoginResponse, loginRequest } from '@pharmaet/contracts';
import { Public } from '../../common/auth/public.decorator';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { AuthService } from './auth.service';

@Controller('auth')
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Public()
  @Post('login')
  @HttpCode(200)
  login(@Body(new ZodValidationPipe(loginRequest)) body: LoginRequest): Promise<LoginResponse> {
    return this.auth.login(body);
  }
}
