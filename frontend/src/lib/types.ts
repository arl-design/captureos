export interface Photo {
  id: number;
  photoId: string;
  url: string;
  thumbUrl: string;
  width: number;
  height: number;
  sizeBytes: number;
  status: 'pending' | 'accepted' | 'discarded';
  capturedAt: string;
  acceptedAt: string | null;
}

export interface Health {
  ok: boolean;
  service: string;
  camera: { ok: boolean; camera: string };
}

export interface GalleryResponse {
  total: number;
  photos: Photo[];
}

export interface Settings {
  countdown_seconds: number;
  preview_hold_seconds: number;
  jpeg_quality: number;
  max_width: number;
  thumb_width: number;
  gallery_title: string;
  slideshow_interval_seconds: number;
  gallery_mode: 'grid' | 'slideshow';
}
