//
//  Card.swift
//  CardVault
//
//  Created by Johnny Franks on 5/25/25.
//


import SwiftUI


struct CardDetailView: View {
  @State var card: Card

  var body: some View {
    Form {
      TextField("Nickname", text: $card.nickname)
      // SecureField + “Show” toggle to load from Keychain
      SecureField("Card Number", text: .constant("•••• •••• •••• ••••"))
      HStack {
        TextField("MM/YY", text: .constant(""))
        TextField("CVV", text: .constant(""))
      }
      // …more fields…
    }
    .padding()
    .frame(minWidth: 300)
  }
}
