/// <reference types="vite/client" />

declare module "jd-wasm?url" {
  const url: string;
  export default url;
}

/** `.version` from core/build.zig.zon, injected at build time. */
declare const __JD_VERSION__: string;

// The parts of the File System Access API (WICG) the page uses where present;
// not in TypeScript's DOM library.
interface FileSystemHandlePermissionDescriptor {
  mode?: "read" | "readwrite";
}
interface FileSystemHandle {
  queryPermission?(descriptor?: FileSystemHandlePermissionDescriptor): Promise<PermissionState>;
  requestPermission?(descriptor?: FileSystemHandlePermissionDescriptor): Promise<PermissionState>;
}
interface FilePickerAcceptType {
  description?: string;
  accept: Record<string, string[]>;
}
interface OpenFilePickerOptions {
  types?: FilePickerAcceptType[];
  excludeAcceptAllOption?: boolean;
  multiple?: boolean;
  id?: string;
  startIn?: string;
}
interface SaveFilePickerOptions {
  types?: FilePickerAcceptType[];
  excludeAcceptAllOption?: boolean;
  suggestedName?: string;
  id?: string;
  startIn?: string;
}
interface Window {
  showOpenFilePicker?(options?: OpenFilePickerOptions): Promise<FileSystemFileHandle[]>;
  showSaveFilePicker?(options?: SaveFilePickerOptions): Promise<FileSystemFileHandle>;
}
