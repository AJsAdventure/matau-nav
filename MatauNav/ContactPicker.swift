import SwiftUI

// MARK: - ContactPicker
//
// Picks a name + phone number for an AIS-friend tag.
// iOS: a thin wrapper around CNContactPickerViewController so the editor can
// pull straight from the address book.
// macOS: CNContactPickerViewController doesn't exist, so present a small
// manual-entry form with the same onPick(name, phone) contract.

#if canImport(UIKit)
import ContactsUI

struct ContactPicker: UIViewControllerRepresentable {
    var onPick: (String /*name*/, String /*phone*/) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let p = CNContactPickerViewController()
        p.delegate = context.coordinator
        // Display only contacts with at least one phone number
        p.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        p.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        return p
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        init(_ p: ContactPicker) { parent = p }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespaces)
            let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
            parent.onPick(name, phone)
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            let contact = contactProperty.contact
            let name = "\(contact.givenName) \(contact.familyName)"
                .trimmingCharacters(in: .whitespaces)
            let phone = (contactProperty.value as? CNPhoneNumber)?.stringValue
                     ?? contact.phoneNumbers.first?.value.stringValue
                     ?? ""
            parent.onPick(name, phone)
        }
    }
}

#else

struct ContactPicker: View {
    var onPick: (String /*name*/, String /*phone*/) -> Void
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add friend").font(.headline)
            Text("Enter a name and phone number for this vessel.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
            Form {
                TextField("Name", text: $name)
                TextField("Phone", text: $phone)
            }
            .frame(minWidth: 320)
            HStack {
                Button("Cancel") { onCancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    onPick(name.trimmingCharacters(in: .whitespaces),
                           phone.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }
}

#endif
