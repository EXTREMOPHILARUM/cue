import SwiftUI

struct CallCard:ViewModifier {
    func body(content:Content) -> some View {
        content.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(CallPalette.surface,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(CallPalette.outline,lineWidth:1))
    }
}

struct CallSectionHeading:View {
    let title:String
    let subtitle:String
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {Text(subtitle).font(.callout).foregroundStyle(CallPalette.muted).fixedSize(horizontal:false,vertical:true)}
        }
    }
}

struct CallEmptyState:View {
    let symbol:String
    let title:String
    let message:String
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Image(systemName:symbol).font(.system(size:24,weight:.light))
                .frame(width:52,height:52).background(CallPalette.surface,in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(CallPalette.outline)).accessibilityHidden(true)
            Text(title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(message).foregroundStyle(CallPalette.muted).lineSpacing(5).fixedSize(horizontal:false,vertical:true)
        // Avoid zero-width text measurement inflating the native window's minimum height.
        }.frame(minWidth:240,maxWidth:420,alignment:.leading)
    }
}
