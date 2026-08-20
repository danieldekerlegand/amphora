import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * TurboModule spec.
 *
 * Note what is absent: there is no `uploadChunk`, no `readFile`, no transfer loop. JavaScript
 * does not run while the app is suspended, so any JS-driven transfer fails the backgrounding
 * requirement by construction — which is precisely why the existing React Native uploaders
 * cannot meet it. This surface is commands in, coalesced events out. Nothing else.
 *
 * See docs/reference/platform-constraints.md §3.
 */
export interface Spec extends TurboModule {
  /**
   * Resolves after the launch reconciler has joined the durable job registry against the
   * platform task registry (iOS `getAllTasks`, Android `getWorkInfosByTag`). Call this before
   * rendering upload UI; until it resolves, `getJobs` may report stale states.
   */
  ready(): Promise<Object>;

  enqueue(request: Object): Promise<string>;
  pause(id: string): Promise<void>;
  resume(id: string): Promise<void>;
  /** Valid for a job this process has never seen running. */
  cancel(id: string): Promise<void>;
  retry(id: string): Promise<void>;

  getJob(id: string): Promise<Object | null>;
  getJobs(): Promise<Object[]>;

  // Progress is coalesced natively to ≤1 Hz per job. Emitting per flush for a multi-GB upload
  // saturates the bridge and stalls the UI thread. See state-machine.md I9.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Amphora');
