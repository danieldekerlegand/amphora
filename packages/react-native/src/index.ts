import { NativeEventEmitter, NativeModules } from 'react-native';
import NativeAmphora from './NativeAmphora';
import type { AmphoraEvent, ReadyReport, UploadJob, UploadRequest } from './types';

export * from './types';

const emitter = new NativeEventEmitter(NativeModules.Amphora);

let readyPromise: Promise<ReadyReport> | null = null;

/**
 * Await this before showing upload UI.
 *
 * On a cold start after the app was killed mid-upload, this is what turns "we have some rows in
 * a database" into "we know which uploads are still running natively, which are orphaned but
 * resumable, and which are gone". Memoized: safe to call from several components.
 */
export function ready(): Promise<ReadyReport> {
  readyPromise ??= NativeAmphora.ready() as Promise<ReadyReport>;
  return readyPromise;
}

export function enqueue(request: UploadRequest): Promise<string> {
  return NativeAmphora.enqueue(request);
}

export const pause = (id: string) => NativeAmphora.pause(id);
export const resume = (id: string) => NativeAmphora.resume(id);
export const cancel = (id: string) => NativeAmphora.cancel(id);
export const retry = (id: string) => NativeAmphora.retry(id);

export function getJob(id: string): Promise<UploadJob | null> {
  return NativeAmphora.getJob(id) as Promise<UploadJob | null>;
}

/** The full registry, including completed jobs inside the retention window. */
export function getJobs(): Promise<UploadJob[]> {
  return NativeAmphora.getJobs() as Promise<UploadJob[]>;
}

export function addListener(fn: (event: AmphoraEvent) => void): () => void {
  const sub = emitter.addListener('amphora', fn);
  return () => sub.remove();
}

/**
 * Convenience for the common host-app shape: reconcile, then hand back the surviving jobs.
 *
 * ```ts
 * const { report, jobs } = await restoreUploads();
 * // report.adopted are still transferring; report.recovered were picked back up from the
 * // server's offset; every one of them can be paused or canceled from here.
 * ```
 */
export async function restoreUploads(): Promise<{ report: ReadyReport; jobs: UploadJob[] }> {
  const report = await ready();
  const jobs = await getJobs();
  return { report, jobs };
}
