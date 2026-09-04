import SwiftUI

struct ImageManagerView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        HStack(spacing: 0) {
            // 左边：新建/打包 RAW 硬盘表单区域
            VStack(alignment: .leading, spacing: 18) {
                Text("Storage Image Creator")
                    .font(.title2)
                    .fontWeight(.bold)
                
                VStack(alignment: .leading, spacing: 14) {
                    Text("Virtual Volume Specs")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Disk Image Filename")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. windows11_pro", text: $state.newImageName)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Volume Capacity (Ignored if Folder selected)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Stepper("Size (GB): \(state.newImageSizeGB) GB", value: $state.newImageSizeGB, in: 4...1024, step: 10)
                            .font(.body)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // 新增：可选的系统源文件夹选择
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Source System Folder (Optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if !state.selectedSourceFolderPath.isEmpty {
                                Button("Clear") {
                                    state.selectedSourceFolderPath = ""
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.blue)
                                .font(.caption)
                            }
                        }
                        
                        HStack {
                            TextField("Blank Image (Ready for Manual Install)", text: $state.selectedSourceFolderPath)
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)
                            
                            Button("Browse...") {
                                state.selectSourceFolder()
                            }
                        }
                        Text("Select a folder containing OS system files to bundle as a Bootable Disk directly.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                Button(action: { state.createDiskImage() }) {
                    HStack {
                        if state.isCreatingDisk {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                        Text(state.selectedSourceFolderPath.isEmpty ? "Create Blank RAW Image" : "Bundle Folder as RAW Boot Disk")
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(state.isCreatingDisk || state.newImageName.isEmpty)
                
                if let err = state.diskCreationError {
                    Text("Error: \(err)")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                
                Spacer()
            }
            .padding()
            .frame(width: 350)
            
            Divider()
            
            // 右边：现有镜像选择列表，作为 iSCSI 无盘启动盘块媒介绑定源
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Disk Images Archive")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    
                    // 新增：打开并支持导入本地任意位置 .img 文件
                    Button(action: { state.importImageViaFilePicker() }) {
                        Label("Open External .img...", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
                
                if state.availableImages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.minus")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Archive empty. Click 'Open External' or 'Create' above.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(state.availableImages, id: \.self, selection: Binding(
                        get: { URL(fileURLWithPath: state.selectedImagePath) },
                        set: { state.selectedImagePath = $0?.path ?? "" }
                    )) { url in
                        HStack {
                            Image(systemName: "internaldrive.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                    .fontWeight(.medium)
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            
                            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                            Text(String(format: "%.2f GB", Double(size) / 1024 / 1024 / 1024))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            state.scanForImages()
        }
    }
}
