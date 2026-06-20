import {
  Controller,
  Delete,
  Head,
  HttpCode,
  HttpStatus,
  NotFoundException,
  Param,
  Patch,
  Post,
  Req,
  Res,
} from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Request, Response } from 'express';
import { ApiTag } from 'src/enum';
import { Auth, Authenticated } from 'src/middleware/auth.guard';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { TusUploadService } from 'src/services/tus-upload.service';

@ApiTags(ApiTag.TusUpload)
@Controller('tus/uploads')
export class TusUploadController {
  constructor(
    private logger: LoggingRepository,
    private tusService: TusUploadService,
  ) {}

  @Head(':id')
  @Authenticated({ permission: 'asset.upload' as any })
  async headUpload(
    @Auth() auth: any,
    @Param('id') id: string,
    @Res() res: Response,
  ) {
    const metadata = await this.tusService.getUploadStatus(id);
    if (!metadata) {
      throw new NotFoundException('Upload not found');
    }

    res.set({
      'Tus-Resumable': '1.0.0',
      'Upload-Offset': metadata.offset.toString(),
      'Upload-Length': metadata.length.toString(),
      'Upload-Metadata': `filename ${Buffer.from(metadata.filename).toString('base64')},contentType ${Buffer.from(metadata.contentType).toString('base64')}`,
      'Cache-Control': 'no-store',
    });
    res.status(HttpStatus.OK).end();
  }

  @Post()
  @Authenticated({ permission: 'asset.upload' as any })
  @HttpCode(HttpStatus.CREATED)
  async createUpload(
    @Auth() auth: any,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const length = parseInt(req.headers['upload-length'] || '0', 10);
    const metadataHeader = req.headers['upload-metadata'] as string | undefined;

    if (!length || length <= 0) {
      res.status(HttpStatus.BAD_REQUEST).json({ error: 'Upload-Length header required' });
      return;
    }

    const { id, location } = await this.tusService.createUpload(
      auth.user.id,
      length,
      metadataHeader,
    );

    const fullUrl = `${req.protocol}://${req.get('host')}${location}`;
    res.set({
      'Tus-Resumable': '1.0.0',
      'Location': fullUrl,
      'Upload-Offset': '0',
      'Cache-Control': 'no-store',
    });
    res.status(HttpStatus.CREATED).end();
  }

  @Patch(':id')
  @Authenticated({ permission: 'asset.upload' as any })
  @HttpCode(HttpStatus.NO_CONTENT)
  async patchUpload(
    @Auth() auth: any,
    @Param('id') id: string,
    @Req() req: Request,
    @Res() res: Response,
  ) {
    const offset = parseInt(req.headers['upload-offset'] || '-1', 10);
    if (offset < 0) {
      res.status(HttpStatus.BAD_REQUEST).json({ error: 'Upload-Offset header required' });
      return;
    }

    try {
      const { newOffset, complete } = await this.tusService.patchUpload(
        id,
        offset,
        req as any,
      );

      res.set({
        'Tus-Resumable': '1.0.0',
        'Upload-Offset': newOffset.toString(),
        'Cache-Control': 'no-store',
      });

      if (complete) {
        try {
          const result = await this.tusService.finalizeUpload(id, auth);
          res.set('Immich-Asset-Id', result.id);
          res.set('Immich-Asset-Status', result.status);
        } catch (error) {
          this.logger.error(`TUS finalize error for ${id}: ${error}`);
          res.status(HttpStatus.INTERNAL_SERVER_ERROR).json({
            error: 'Upload received but asset creation failed',
          });
          return;
        }
      }

      res.status(HttpStatus.NO_CONTENT).end();
    } catch (error: any) {
      if (error.message?.includes('Offset mismatch')) {
        res.status(HttpStatus.CONFLICT).json({ error: error.message });
        return;
      }
      if (error.message === 'Upload not found') {
        throw new NotFoundException('Upload not found');
      }
      throw error;
    }
  }

  @Delete(':id')
  @Authenticated({ permission: 'asset.upload' as any })
  @HttpCode(HttpStatus.NO_CONTENT)
  async deleteUpload(
    @Auth() auth: any,
    @Param('id') id: string,
    @Res() res: Response,
  ) {
    await this.tusService.deleteUpload(id);
    res.set({ 'Tus-Resumable': '1.0.0' });
    res.status(HttpStatus.NO_CONTENT).end();
  }
}
