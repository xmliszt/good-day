//
//  AutoTraceSettingsView.swift
//  Joodle
//
//  Detail settings for the auto-trace feature, reached from the "Auto Trace" row
//  in General. The row itself is Pro-gated, so only subscribers land here: a
//  master toggle turns the camera's auto-trace button on or off, and a picker
//  sets the detail level a single tap traces at. Everything below the toggle is
//  disabled while auto-trace is off.
//

import SwiftUI

struct AutoTraceSettingsView: View {
  @Environment(\.userPreferences) private var userPreferences

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { userPreferences.isAutoTraceEnabled },
      set: { newValue in
        let previousValue = userPreferences.isAutoTraceEnabled
        userPreferences.isAutoTraceEnabled = newValue
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(
            name: "auto_trace_enabled",
            value: newValue,
            previousValue: previousValue
          )
        }
      }
    )
  }

  private var detailBinding: Binding<AutoTraceDetail> {
    Binding(
      get: { userPreferences.autoTraceDefaultDetail },
      set: { newValue in
        let previousValue = userPreferences.autoTraceDefaultDetail
        userPreferences.autoTraceDefaultDetail = newValue
        if newValue != previousValue {
          AnalyticsManager.shared.trackSettingChanged(
            name: "auto_trace_default_detail",
            value: newValue.rawValue,
            previousValue: previousValue.rawValue
          )
        }
      }
    )
  }

  var body: some View {
    Form {
      Section {
        Toggle(isOn: enabledBinding) {
          HStack {
            SettingsIconView(systemName: "lasso.and.sparkles", backgroundColor: .pink)
            Text("Auto Trace")
          }
        }
        .tint(.appAccent)
      } footer: {
        Text("Adds a button to the camera view that traces your reference photo into a doodle for you.")
      }

      Section {
        Picker(selection: detailBinding) {
          ForEach(AutoTraceDetail.allCases) { detail in
            Label {
              Text(detail.accessibilityName)
            } icon: {
              SparkleCluster(detail: detail, primaryScale: 0.8)
                .foregroundStyle(.appAccent)
            }
            .tag(detail)
          }
        } label: {
          Text("Default Detail Level")
        }
        // Inline, not the Form's default menu style: a menu renders each option
        // through UIKit, which keeps only a single SF Symbol per label and
        // collapses every level's cluster to one sparkle. Inline rows render the
        // real SwiftUI label, so each level shows its own cluster.
        .pickerStyle(.inline)
        // The label is kept for VoiceOver but hidden — the section header already
        // reads "Default Detail Level", so an inline label row would duplicate it.
        .labelsHidden()
      } header: {
        Text("Default Detail Level")
      } footer: {
        Text("The detail level a single tap traces at. Long-press the auto trace button to pick a different level for one trace.")
      }
      .disabled(!userPreferences.isAutoTraceEnabled)
    }
    .navigationTitle("Auto Trace")
    .navigationBarTitleDisplayMode(.inline)
    .postHogScreenView("Auto Trace Settings")
  }
}

#Preview {
  NavigationStack {
    AutoTraceSettingsView()
  }
}
