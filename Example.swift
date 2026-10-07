import Foundation

/// A simple example Swift file demonstrating basic language features.
struct Person {
    let name: String
    let age: Int

    func greet() -> String {
        return "Hello, my name is \(name) and I am \(age) years old."
    }
}

func main() {
    let people = [
        Person(name: "Alice", age: 30),
        Person(name: "Bob", age: 25)
    ]

    for person in people {
        print(person.greet())
    }
}

main()
