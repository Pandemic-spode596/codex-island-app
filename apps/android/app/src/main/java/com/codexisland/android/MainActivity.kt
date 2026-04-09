package com.codexisland.android

import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import com.codexisland.android.databinding.ActivityMainBinding
import com.codexisland.android.shell.bootstrap.ShellBootstrapUiState
import com.codexisland.android.shell.bootstrap.ShellBootstrapViewModel

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding

    private val viewModel: ShellBootstrapViewModel by viewModels {
        ShellBootstrapViewModel.factory(applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.saveHostButton.setOnClickListener {
            viewModel.saveHostProfile(
                deviceName = binding.deviceNameEditText.text?.toString().orEmpty(),
                hostConnectionInput = binding.hostConnectionEditText.text?.toString().orEmpty(),
                hostDisplayName = binding.hostDisplayNameEditText.text?.toString().orEmpty(),
                authToken = binding.authTokenEditText.text?.toString().orEmpty(),
                pairingCode = binding.pairingCodeEditText.text?.toString().orEmpty()
            )
        }
        binding.refreshButton.setOnClickListener { viewModel.refreshRuntime() }
        binding.nextHostButton.setOnClickListener { viewModel.selectNextHost() }
        binding.startThreadButton.setOnClickListener { viewModel.startThread() }
        binding.nextThreadButton.setOnClickListener { viewModel.selectNextThread() }
        binding.resumeThreadButton.setOnClickListener { viewModel.resumeThread() }
        binding.sendMessageButton.setOnClickListener {
            viewModel.sendMessage(binding.messageEditText.text?.toString().orEmpty())
        }
        binding.interruptThreadButton.setOnClickListener { viewModel.interruptThread() }
        binding.allowApprovalButton.setOnClickListener { viewModel.allowApproval() }
        binding.denyApprovalButton.setOnClickListener { viewModel.denyApproval() }
        binding.submitInputButton.setOnClickListener {
            viewModel.submitUserInput(binding.userInputAnswerEditText.text?.toString().orEmpty())
        }

        viewModel.uiState.observe(this, ::render)
    }

    private fun render(state: ShellBootstrapUiState) {
        syncText(binding.deviceNameEditText.text?.toString(), state.deviceName, binding.deviceNameEditText.isFocused) {
            binding.deviceNameEditText.setText(it)
        }
        syncText(binding.authTokenEditText.text?.toString(), state.authToken, binding.authTokenEditText.isFocused) {
            binding.authTokenEditText.setText(it)
        }
        syncText(binding.hostConnectionEditText.text?.toString(), state.hostConnectionInput, binding.hostConnectionEditText.isFocused) {
            binding.hostConnectionEditText.setText(it)
        }
        syncText(binding.hostDisplayNameEditText.text?.toString(), state.hostDisplayName, binding.hostDisplayNameEditText.isFocused) {
            binding.hostDisplayNameEditText.setText(it)
        }
        syncText(binding.pairingCodeEditText.text?.toString(), state.pairingCode, binding.pairingCodeEditText.isFocused) {
            binding.pairingCodeEditText.setText(it)
        }
        syncText(binding.messageEditText.text?.toString(), state.messageDraft, binding.messageEditText.isFocused) {
            binding.messageEditText.setText(it)
        }
        syncText(binding.userInputAnswerEditText.text?.toString(), state.userInputDraft, binding.userInputAnswerEditText.isFocused) {
            binding.userInputAnswerEditText.setText(it)
        }

        binding.shellSubtitle.text = state.subtitle
        binding.runtimeStatusChip.text = state.runtimeStatus
        binding.activeHostSummaryValue.text = state.activeHostSummary
        binding.hostProfilesValue.text = state.hostProfilesSummary
        binding.threadListValue.text = state.threadListSummary
        binding.activeThreadValue.text = state.activeThreadSummary
        binding.chatTranscriptValue.text = state.chatTranscript
        binding.approvalValue.text = state.approvalSummary
        binding.userInputValue.text = state.userInputSummary
        binding.engineStatusValue.text = state.engineStatus
        binding.bindingValue.text = state.bindingSurface
        binding.connectionValue.text = state.connection
        binding.queueValue.text = state.commandQueue
        binding.pairedDevicesValue.text = state.pairedDevices
        binding.reconnectValue.text = state.reconnect
        binding.diagnosticsValue.text = state.diagnostics
        binding.lastErrorValue.text = state.lastError
        binding.helloCommandPreviewValue.text = state.helloCommandPreview
        binding.pairStartPreviewValue.text = state.pairStartPreview
        binding.pairConfirmPreviewValue.text = state.pairConfirmPreview
        binding.reconnectPreviewValue.text = state.reconnectPreview
        binding.threadListPreviewValue.text = state.threadListPreview
        binding.threadStartPreviewValue.text = state.threadStartPreview
        binding.threadResumePreviewValue.text = state.threadResumePreview
        binding.turnStartPreviewValue.text = state.turnStartPreview
        binding.turnSteerPreviewValue.text = state.turnSteerPreview
        binding.interruptPreviewValue.text = state.interruptPreview
        binding.nextStepsValue.text = state.nextSteps
        binding.authTokenInputLayout.helperText = state.authTokenHelper
    }

    private fun syncText(current: String?, expected: String, isFocused: Boolean, update: (String) -> Unit) {
        if (!isFocused && current != expected) {
            update(expected)
        }
    }
}
