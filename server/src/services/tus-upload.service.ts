import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { LoggingRepository } from 'src/repositories/logging.repository';
import { StorageRepository } from 'src/repositories/storage.repository';
import { AssetMediaService } from 'src/services/asset-media.service';
import { StorageFolder } from 'src/enum';

interface TusUploadMetadata {
  id: string;
  offset: number;
  length: number;
  filename: string;
  contentType: string;
  userId: string;
  createdAt: string;
  fields: Record<string, string>;
}

@Injectable()
export class TusUploadService {
  constructor(
    private logger: LoggingRepository,
    private storageRepository: StorageRepository,
    private assetMediaService: AssetMediaService,
  ) {}

  private getUploadDir(uploadId: string): string {
    return join(this.storageRepository.getBaseFolder(StorageFolder.Upload), 'tus', uploadId);
  }

  private getDataPath(uploadId: string): string {
    return join(this.getUploadDir(uploadId), 'data');
  }

  private getMetadataPath(uploadId: string): string {
    return join(this.getUploadDir(uploadId), 'metadata.json');
  }

  async createUpload(
    userId: string,
    length: number,
    metadataHeader: string | undefined,
  ): Promise<{ id: string; location: string }> {
    const id = randomUUID();
    const dir = this.getUploadDir(id);
    mkdirSync(dir, { recursive: true });

    let filename = 'unknown';
    let contentType = 'application/octet-stream';
    let fields: Record<string, string> = {};

    if (metadataHeader) {
      const pairs = metadataHeader.split(',');
      for (const pair of pairs) {
        const trimmed = pair.trim();
        const spaceIdx = trimmed.indexOf(' ');
        if (spaceIdx === -1) continue;
        const key = trimmed.substring(0, spaceIdx);
        const valueB64 = trimmed.substring(spaceIdx + 1);
        const value = Buffer.from(valueB64, 'base64').toString('utf-8');
        if (key === 'filename') filename = value;
        else if (key === 'contentType') contentType = value;
        else if (key === 'fields') fields = JSON.parse(value);
      }
    }

    const metadata: TusUploadMetadata = {
      id,
      offset: 0,
      length,
      filename,
      contentType,
      userId,
      createdAt: new Date().toISOString(),
      fields,
    };

    writeFileSync(this.getMetadataPath(id), JSON.stringify(metadata, null, 2));
    writeFileSync(this.getDataPath(id), '');

    this.logger.log(`TUS upload created: ${id} (${filename}, ${length} bytes) for user ${userId}`);

    return { id, location: `/api/tus/uploads/${id}` };
  }

  async getUploadStatus(uploadId: string): Promise<TusUploadMetadata | null> {
    const metaPath = this.getMetadataPath(uploadId);
    if (!existsSync(metaPath)) {
      return null;
    }
    return JSON.parse(readFileSync(metaPath, 'utf-8')) as TusUploadMetadata;
  }

  async patchUpload(
    uploadId: string,
    offset: number,
    stream: Readable,
  ): Promise<{ newOffset: number; complete: boolean }> {
    const metadata = await this.getUploadStatus(uploadId);
    if (!metadata) {
      throw new Error('Upload not found');
    }

    if (offset !== metadata.offset) {
      throw new Error(`Offset mismatch: expected ${metadata.offset}, got ${offset}`);
    }

    const dataPath = this.getDataPath(uploadId);

    await new Promise<void>((resolve, reject) => {
      const writeStream = createWriteStream(dataPath, { flags: 'a' });
      stream.pipe(writeStream);
      writeStream.on('finish', resolve);
      writeStream.on('error', reject);
      stream.on('error', reject);
    });

    const size = statSync(dataPath).size;
    metadata.offset = size;
    writeFileSync(this.getMetadataPath(uploadId), JSON.stringify(metadata, null, 2));

    const complete = metadata.offset >= metadata.length;

    if (complete) {
      this.logger.log(`TUS upload complete: ${uploadId} (${metadata.filename})`);
    }

    return { newOffset: metadata.offset, complete };
  }

  async finalizeUpload(uploadId: string, auth: any): Promise<{ id: string; status: string }> {
    const metadata = await this.getUploadStatus(uploadId);
    if (!metadata) {
      throw new Error('Upload not found');
    }

    const dataPath = this.getDataPath(uploadId);
    const dir = this.getUploadDir(uploadId);

    const ext = metadata.filename.includes('.')
      ? '.' + metadata.filename.split('.').pop()
      : '';
    const finalDir = join(
      this.storageRepository.getBaseFolder(StorageFolder.Upload),
      metadata.userId,
      uploadId,
    );
    const finalFilename = `${uploadId}${ext}`;
    const finalPath = join(finalDir, finalFilename);

    mkdirSync(finalDir, { recursive: true });
    renameSync(dataPath, finalPath);

    rmSync(dir, { recursive: true, force: true });

    const crypto = require('node:crypto');
    const fileBuffer = readFileSync(finalPath);
    const checksum = crypto.createHash('sha1').update(fileBuffer).digest();

    const uploadFile = {
      path: finalPath,
      size: metadata.length,
      checksum: Buffer.from(checksum),
      originalName: metadata.filename,
      mimeType: metadata.contentType,
    };

    const dto = {
      ...metadata.fields,
      fileCreatedAt: metadata.fields['fileCreatedAt'] || metadata.createdAt,
      fileModifiedAt: metadata.fields['fileModifiedAt'] || new Date().toISOString(),
      filename: metadata.filename,
    };

    const result = await this.assetMediaService.uploadAsset(
      auth,
      dto as any,
      uploadFile as any,
      undefined,
    );

    return result;
  }

  async deleteUpload(uploadId: string): Promise<void> {
    const dir = this.getUploadDir(uploadId);
    if (existsSync(dir)) {
      rmSync(dir, { recursive: true, force: true });
      this.logger.log(`TUS upload deleted: ${uploadId}`);
    }
  }
}
